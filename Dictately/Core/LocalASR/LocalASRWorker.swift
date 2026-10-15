import Foundation

/// worker 转写结果（协议 result 字段）。
struct LocalWorkerResult: Equatable {
    let text: String
    let durationSeconds: Int?
}

/// worker 脚本资源定位（SoundFeedback 双路径同款：SPM process 对子目录可能打平，
/// 先查 bundle 根再查 Scripts/ 子目录）。
enum LocalWorkerResources {
    static func scriptURL(bundle: Bundle = AppResources.bundle) -> URL? {
        bundle.url(forResource: "local_asr_worker", withExtension: "py")
            ?? bundle.url(forResource: "local_asr_worker", withExtension: "py", subdirectory: "Scripts")
    }
}

/// worker 通信错误（映射进 ASRError.localEngineFailed，消息截断后展示）。
/// 超时不设独立 case——超时收口复用 Reply 通道，最终也走 commandFailed
/// （error 文案含 "timed out"，可辨识）。
enum LocalWorkerError: Error, Equatable {
    case launchFailed(String)
    case commandFailed(String)
    case exited(String)
}

/// worker 进程控制接缝（测试注入 fake；协议方法按 worker.py 命令一一对应）。
protocol LocalWorkerControlling: AnyObject {
    var isRunning: Bool { get }
    /// 进程号（未运行 = nil；状态条 CPU/内存监控采样用）。
    var workerPID: Int32? { get }
    /// 启动常驻进程（已运行 = no-op）。
    func start() async throws
    func ping() async throws
    func load(modelPath: String) async throws
    func transcribe(audioPath: String) async throws -> LocalWorkerResult
    func terminate()
}

/// 进程资源读取（proc_pidinfo/PROC_PIDTASKINFO；设置页状态条 CPU/内存监控用）。
/// 注：Darwin Swift 导入层不含 pti_phys_footprint 字段，proc_pid_rusage 的
/// raw 指针形态 Swift 下实测崩溃——勿换此实现（2026-10-11）。
enum ProcessMemory {
    /// 单次采样：常驻物理内存 + 累计 CPU 时间（pti_total_user/system，XNU 已
    /// 换算为纳秒——与 psutil macOS 口径一致）。
    struct Snapshot: Equatable {
        let residentBytes: Int64
        let totalCPUNanos: Int64
    }

    /// 资源快照；进程不在/无权限返回 nil。
    static func snapshot(pid: Int32) -> Snapshot? {
        var info = proc_taskinfo()
        let filled = proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
        guard filled == MemoryLayout<proc_taskinfo>.stride else { return nil }
        return Snapshot(
            residentBytes: Int64(info.pti_resident_size),
            totalCPUNanos: Int64(info.pti_total_user) + Int64(info.pti_total_system))
    }

    /// 常驻物理内存（字节）；进程不在/无权限返回 nil。
    static func residentBytes(pid: Int32) -> Int64? {
        snapshot(pid: pid)?.residentBytes
    }

    /// CPU 占用率（0–100，按逻辑核数归一）：两次采样间累计 CPU 时间差 ÷ 墙钟差。
    /// 墙钟差非正 / CPU 差为负（进程重启导致累计时间回退）返回 nil，由调用方重置基线。
    static func cpuPercent(cpuDeltaNanos: Int64, wallDeltaNanos: Int64) -> Double? {
        guard wallDeltaNanos > 0, cpuDeltaNanos >= 0 else { return nil }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let ratio = Double(cpuDeltaNanos) / Double(wallDeltaNanos) / Double(cores)
        return min(100, ratio * 100)
    }
}

/// worker.py 常驻进程实现：stdin/stdout JSON-lines、并发请求按 id 配对、
/// 超时与进程退出的收口、stderr 逐行接 AppLog。
///
/// 锁纪律：pending 字典与进程/句柄状态全部经 `lock.withLock`（Foundation
/// 同步辅助）访问——锁内不做任何等待、不跨 await 持有（Swift 6 前置约束）。
final class PythonWorkerProcess: LocalWorkerControlling {
    struct Reply: Equatable {
        let ok: Bool
        let text: String?
        let duration: Int?
        let error: String?
    }

    private let pythonURL: URL
    private let scriptURL: URL
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<Reply, Never>] = [:]

    /// 命令超时（load 含权重加载 + Metal warmup 放宽 5 分钟；transcribe 3 分钟）。
    private let loadTimeout: TimeInterval = 300
    private let transcribeTimeout: TimeInterval = 180

    init(pythonURL: URL, scriptURL: URL) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
    }

    // MARK: - 同步锁辅助（锁内不做任何等待）

    private func takePending(id: Int64) -> CheckedContinuation<Reply, Never>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func takeAllPending() -> [Int64: CheckedContinuation<Reply, Never>] {
        lock.withLock {
            let waiting = pending
            pending = [:]
            return waiting
        }
    }

    // MARK: - LocalWorkerControlling

    var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    var workerPID: Int32? {
        lock.withLock {
            guard let process, process.isRunning else { return nil }
            return process.processIdentifier
        }
    }

    func start() async throws {
        // 调用前提：上游（DictationPipeline 相位机）串行化转写——同一时刻至多
        // 一条命令链在途。若未来出现并发调用方，isRunning 检查与进程赋值间的
        // 窗口会双 spawn 并泄漏旧进程，届时需引入 single-flight。
        if isRunning { return }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { return }
            AppLog.pipeline.notice("asr-worker: \(line, privacy: .public)")
        }

        do {
            try process.run()
        } catch {
            // 启动失败也要回收 stderr handler（成功路径由 terminationHandler 清）
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw LocalWorkerError.launchFailed(error.localizedDescription)
        }

        lock.withLock {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
        }

        // stdout 逐行读 → JSON → 按 id 配对 resume（unstructured task 运行至
        // EOF 自行收口，无需持有引用）
        let channel = stdoutPipe.fileHandleForReading
        Task { [weak self] in
            do {
                for try await line in channel.bytes.lines {
                    guard let self, let data = line.data(using: .utf8),
                          let decoded = Self.decode(data),
                          let id = decoded.id,
                          let continuation = self.takePending(id: id)
                    else { continue }
                    continuation.resume(returning: decoded.reply)
                }
            } catch {
                // 流取消/中断：与流结束同样收口
            }
            guard let self else { return }
            for continuation in self.takeAllPending().values {
                continuation.resume(returning: Self.exitedReply())
            }
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let waiting = self.takeAllPending()
            self.lock.withLock {
                if self.process === process {
                    self.process = nil
                    if let stdin = self.stdinHandle { try? stdin.close() }
                    self.stdinHandle = nil
                }
            }
            for continuation in waiting.values {
                continuation.resume(returning: Self.exitedReply())
            }
        }

        // 启动即 ping 验证（python 起来 + mlx_audio 可导入）；失败即回收
        do {
            try await ping()
        } catch {
            terminate()
            throw error
        }
    }

    func ping() async throws {
        let reply = try await send(["cmd": "ping"], timeout: 60)
        guard reply.ok else { throw LocalWorkerError.commandFailed(reply.error ?? "ping failed") }
    }

    func load(modelPath: String) async throws {
        let reply = try await send(["cmd": "load", "model": modelPath], timeout: loadTimeout)
        guard reply.ok else { throw LocalWorkerError.commandFailed(reply.error ?? "load failed") }
    }

    func transcribe(audioPath: String) async throws -> LocalWorkerResult {
        let reply = try await send(["cmd": "transcribe", "audio": audioPath], timeout: transcribeTimeout)
        guard reply.ok else { throw LocalWorkerError.commandFailed(reply.error ?? "transcribe failed") }
        return LocalWorkerResult(text: reply.text ?? "", durationSeconds: reply.duration)
    }

    func terminate() {
        // 在途命令的续体必须先取出并逐个 resume——只清字典不 resume 会让对应
        // await 永远挂起（读端 EOF / 进程退出回调 / 超时兜底随后都取不到已被
        // 清空的续体；bug03：空闲卸载竞态杀掉加载中的 worker，HUD 永久卡「转写中」）
        let (process, stdin, waiting) = lock.withLock { () -> (Process?, FileHandle?, [CheckedContinuation<Reply, Never>]) in
            let waiting = Array(pending.values)
            pending = [:]
            let (process, stdin) = (self.process, self.stdinHandle)
            self.process = nil
            self.stdinHandle = nil
            return (process, stdin, waiting)
        }
        if let stdin { try? stdin.close() }
        for continuation in waiting {
            continuation.resume(returning: Self.exitedReply())
        }
        process?.terminate()
    }

    // MARK: - 私有

    private static func exitedReply() -> Reply {
        Reply(ok: false, text: nil, duration: nil, error: "worker process exited")
    }

    private func send(_ payload: [String: Any], timeout: TimeInterval) async throws -> Reply {
        let prepared = lock.withLock { () -> (Data, Int64)? in
            guard stdinHandle != nil, process?.isRunning == true else { return nil }
            nextID += 1
            let id = nextID
            var request = payload
            request["id"] = id
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  var line = String(data: data, encoding: .utf8)
            else { return nil }
            line += "\n"
            return (line.data(using: .utf8) ?? Data(), id)
        }
        guard let (lineData, id) = prepared else {
            throw LocalWorkerError.exited("worker not running")
        }

        let reply: Reply = await withCheckedContinuation { continuation in
            // 注册续体与取写端同锁一次完成；stdin 写入放锁外：FileHandle.write
            // 与 reader 读端无共享可变状态
            let stdin = lock.withLock { () -> FileHandle? in
                pending[id] = continuation
                return stdinHandle
            }
            stdin?.write(lineData)

            // 超时兜底：到点未回按超时收口（continuation 已 resume 时为 no-op）
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let continuation = self?.takePending(id: id) else { return }
                let label = payload["cmd"] as? String ?? "command"
                continuation.resume(returning: Reply(
                    ok: false, text: nil, duration: nil, error: "\(label) timed out"))
            }
        }
        guard reply.ok else {
            throw LocalWorkerError.commandFailed(reply.error ?? "unknown worker error")
        }
        return reply
    }

    private static func decode(_ data: Data) -> (id: Int64?, reply: Reply)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = (object["id"] as? NSNumber)?.int64Value
        let ok = object["ok"] as? Bool ?? false
        var text: String?
        var duration: Int?
        if let result = object["result"] as? [String: Any] {
            text = result["text"] as? String
            duration = (result["duration"] as? NSNumber)?.intValue
        }
        return (id, Reply(ok: ok, text: text, duration: duration, error: object["error"] as? String))
    }
}

/// 转写会话：模型常驻加载 + 空闲自动卸载（用户裁决：连续 5 分钟无转写杀进程
/// 释放 1–2.5GB 统一内存；下次转写秒级重载）。
final class LocalASRSession {
    static let idleUnloadInterval: TimeInterval = 5 * 60

    private let controller: LocalWorkerControlling
    private var loadedModelPath: String?
    private var lastActivity = Date.distantPast
    private let clock: () -> Date
    /// 跨线程共享态保护：activeTranscriptions / loadedModelPath / lastActivity
    /// 由 transcribe（协作线程池）与 unloadIfIdle/unload（主线程）读写，一律经
    /// stateLock.withLock 访问（锁内不做任何等待、不跨 await 持有——
    /// PythonWorkerProcess 同款纪律）。
    /// bug03：lastActivity 只在转写成功后更新，首次转写的加载阶段它仍是
    /// distantPast——30s 定时器跳点落在加载窗口即误判「空闲超 5 分钟」杀掉
    /// 刚拉起的 worker；activeTranscriptions > 0 时空闲卸载必须让路。
    private let stateLock = NSLock()
    private var activeTranscriptions = 0

    init(
        controller: LocalWorkerControlling,
        clock: (() -> Date)? = nil
    ) {
        self.controller = controller
        self.clock = clock ?? Date.init
    }

    var isWorkerRunning: Bool { controller.isRunning }

    /// worker 进程资源快照（pti_resident_size + 累计 CPU 时间；未运行 = nil。
    /// 设置页状态条监控用，空闲卸载后自然归 nil → UI 显「模型未加载」归零态）。
    var workerSnapshot: ProcessMemory.Snapshot? {
        guard let pid = controller.workerPID else { return nil }
        return ProcessMemory.snapshot(pid: pid)
    }

    /// 转写入口（引擎调用，任意线程）：确保进程 → 按需载模型 → 转写。
    func transcribe(modelDirectory: URL, audioURL: URL) async throws -> LocalWorkerResult {
        stateLock.withLock { activeTranscriptions += 1 }
        defer { stateLock.withLock { activeTranscriptions -= 1 } }
        if !controller.isRunning {
            // worker 不在跑 = start() 即将拉起全新进程，不可能带着已载模型——
            // 陈旧 loadedModelPath 会让 load 被跳过、新 worker 回「no model
            // loaded」（worker 自行崩溃时无人清此字段，且失败转写还会刷新
            // lastActivity，把自愈拖到 5 分钟空闲卸载之后）。若崩溃尚未被
            // isRunning 察觉，本次 send 会以 exited 干净报错，下次重试经本分支自愈。
            stateLock.withLock { loadedModelPath = nil }
        }
        try await controller.start()
        let path = modelDirectory.standardizedFileURL.path
        if stateLock.withLock({ loadedModelPath }) != path {
            try await controller.load(modelPath: path)
            stateLock.withLock { loadedModelPath = path }
        }
        defer { stateLock.withLock { lastActivity = clock() } }
        return try await controller.transcribe(audioPath: audioURL.standardizedFileURL.path)
    }

    /// 空闲卸载（外部定时驱动，主线程调用）：杀进程并清模型记录。
    func unloadIfIdle() {
        guard !stateLock.withLock({ activeTranscriptions > 0 }) else { return }
        guard controller.isRunning else {
            stateLock.withLock { loadedModelPath = nil }
            return
        }
        guard clock().timeIntervalSince(stateLock.withLock({ lastActivity })) >= Self.idleUnloadInterval else { return }
        // terminate 前复查在途计数，收窄「守卫通过后新转写入场」的窗口。残留
        // 竞态（复查后、terminate 前入场）为已知边界：terminate 会将在途命令以
        // exitedReply 干净收口（转写报错可重试），不再有挂死路径。
        guard !stateLock.withLock({ activeTranscriptions > 0 }) else { return }
        controller.terminate()
        stateLock.withLock { loadedModelPath = nil }
        AppLog.pipeline.notice("local ASR worker idle-unloaded (memory released)")
    }

    /// 即时卸载（无空闲门槛，主线程调用；用户裁决 2026-10-11：切 API 引擎 /
    /// 状态条「卸载」按钮即释放内存）。引擎与 activeLocalModel 不动——下次
    /// 本地转写经 transcribe() 惰性重载。在途转写会被杀但经 exitedReply
    /// 干净报错（即时卸载优先于在途任务，有意为之）。
    func unload() {
        guard controller.isRunning else {
            stateLock.withLock { loadedModelPath = nil }
            return
        }
        controller.terminate()
        stateLock.withLock { loadedModelPath = nil }
        AppLog.pipeline.notice("local ASR worker unloaded (memory released)")
    }
}
