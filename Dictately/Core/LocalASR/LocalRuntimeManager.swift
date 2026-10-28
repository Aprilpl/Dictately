import Foundation

/// 子进程运行结果（exitCode + 合并输出尾部——错误诊断用，正常路径不读全文）。
struct SubprocessResult: Equatable {
    let exitCode: Int32
    /// stdout + stderr 合并，保留末尾 ~16KB（pip 报错在末尾）。
    let output: String
}

/// 子进程运行接缝（全仓首例子进程通道；测试注入 fake 校验命令构造——
/// SystemAudioMuting/SystemAudioOutputIO 双层协议同款手法）。
protocol SubprocessRunning: AnyObject {
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) async -> SubprocessResult
}

extension SubprocessRunning {
    /// 无环境覆盖的便捷入口（协议参数默认值不继承，extension 补齐）。
    func run(_ executable: URL, arguments: [String]) async -> SubprocessResult {
        await run(executable, arguments: arguments, environment: nil)
    }
}

/// Foundation Process 实现：异步等待退出，合并捕获 stdout/stderr 尾部。
final class SubprocessRunner: SubprocessRunning {
    private static let outputLimit = 16 * 1024

    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 管道缓冲区写满会阻塞子进程——readabilityHandler 持续排空
        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [collector] _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.finish()
                continuation.resume(
                    returning: SubprocessResult(
                        exitCode: process.terminationStatus,
                        output: collector.tail))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: SubprocessResult(
                        exitCode: -1,
                        output: "launch failed: \(error.localizedDescription)"))
            }
        }
    }

    /// 线程安全输出累积器（两个 readabilityHandler 并发喂）。
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false

        var tail: String {
            lock.lock(); defer { lock.unlock() }
            let slice = data.count > SubprocessRunner.outputLimit
                ? data.suffix(SubprocessRunner.outputLimit) : data
            return String(data: slice, encoding: .utf8) ?? ""
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            data.append(chunk)
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            finished = true
        }
    }
}

/// 本地转写运行时管理（TASK-134）：包内 PBS Python → 数据目录建 venv →
/// pip 装 mlx-audio（PyPI 失败切清华镜像）→ import 探针通过写就绪标记。
///
/// Python 来源（用户裁决：打包进 .app）：
/// 1. `Contents/Resources/Runtime/python/bin/python3`（build.sh 落位）；
/// 2. 开发旁路：环境变量 `DICTATELY_LOCAL_PYTHON`（裸跑 .build 二进制时指向
///    本机任意 ≥3.10 Python，Debug/Release 均可——只影响无 .app 场景，无凭据语义）。
@Observable
final class LocalRuntimeManager {
    enum Phase: Equatable {
        /// 无可用 Python（包内缺运行时且无环境变量覆盖）——本地分支不可用。
        case unavailable
        /// Python 在，venv 未装。
        case notInstalled
        case installing(InstallStep)
        case ready
        case failed(String)

        enum InstallStep: Equatable {
            case creatingVenv
            case installingPackages
            case verifying
        }

        var isReady: Bool { self == .ready }
    }

    private(set) var phase: Phase = .unavailable

    /// venv 根（数据目录/Runtime/venv；不进 .app——同模型存储纪律）。
    let venvURL: URL
    var venvPythonURL: URL { venvURL.appendingPathComponent("bin/python3") }

    /// 就绪标记文件（探针通过后写，内容以当前钉版为前缀；版本匹配 = 上次安装
    /// 成功，启动即 ready——见 runtimeMarkerMatchesPin）。
    private var readyMarkerURL: URL { venvURL.appendingPathComponent(".dictately-runtime-ready") }

    /// mlx-audio 钉版（升级 = 改这里 + 重装运行时；AGENTS §57 记录）。必须带 [stt]
    /// extra：sentencepiece 是 SenseVoice 等家族的可选依赖（基础安装不含），
    /// 缺失时 mlx-audio 静默回退成输出原始 token ID 数字串（bug02，AGENTS §61）。
    static let mlxAudioPin = "mlx-audio[stt]==0.5.8"
    static let tsinghuaMirror = "https://pypi.tuna.tsinghua.edu.cn/simple"

    private let runner: SubprocessRunning
    private let pythonProvider: () -> URL?
    /// 安装任务（测试 await 其 value 断言终态；private(set)）。
    private(set) var installTask: Task<Void, Never>?

    init(
        dataRoot: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        pythonProvider: (() -> URL?)? = nil
    ) {
        self.venvURL = dataRoot.appendingPathComponent("Runtime/venv", isDirectory: true)
        self.runner = runner
        self.pythonProvider = pythonProvider ?? Self.defaultPythonProvider
        refresh()
    }

    /// 默认 Python 定位：环境变量旁路 → .app 包内 Runtime。
    static func defaultPythonProvider() -> URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DICTATELY_LOCAL_PYTHON"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let bundled = resourceURL
            .appendingPathComponent("Runtime/python/bin/python3", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    /// 从磁盘重算 phase（启动与外部变更后调用；主线程）。
    func refresh() {
        guard pythonProvider() != nil else {
            phase = .unavailable
            return
        }
        if runtimeMarkerMatchesPin() {
            phase = .ready
        } else {
            phase = .notInstalled
        }
    }

    /// 探针式就绪检查（磁盘标记同步判定；引擎在后台线程调用）。
    var isReadyOnDisk: Bool {
        runtimeMarkerMatchesPin()
    }

    /// 就绪标记必须以当前钉版为前缀才有效（安装时写入 `"<pin> ready at <date>"`）。
    /// 陈旧标记（旧钉版装的运行时）当场删除并判未就绪——改钉版后存量 venv
    /// 降级 notInstalled，经横幅一键重装在原 venv 上补装新依赖（venv/pip 幂等）。
    private func runtimeMarkerMatchesPin() -> Bool {
        guard let stamp = try? String(contentsOf: readyMarkerURL, encoding: .utf8) else { return false }
        if stamp.hasPrefix(Self.mlxAudioPin) { return true }
        try? FileManager.default.removeItem(at: readyMarkerURL)
        return false
    }

    /// 安装运行时（幂等守卫；进度经 phase 流转，UI 直接观察）。
    func install() {
        guard case .notInstalled = phase else { return }
        guard let python = pythonProvider() else {
            phase = .unavailable
            return
        }
        phase = .installing(.creatingVenv)
        let runner = runner
        let venvURL = venvURL
        let venvPython = venvPythonURL
        let readyMarker = readyMarkerURL

        installTask = Task { [weak self] in
            // 1. venv
            let venvResult = await runner.run(
                python, arguments: ["-m", "venv", venvURL.path])
            guard venvResult.exitCode == 0 else {
                await MainActor.run { self?.fail("venv 创建失败：\(venvResult.output.suffix(200))") }
                return
            }
            await MainActor.run { self?.phase = .installing(.installingPackages) }

            // 2. pip install（PyPI → 清华镜像 fallback）
            let baseArgs = ["-m", "pip", "install", "--no-input", "--disable-pip-version-check", LocalRuntimeManager.mlxAudioPin]
            var result = await runner.run(venvPython, arguments: baseArgs)
            if result.exitCode != 0 {
                AppLog.pipeline.notice("pip default index failed, retrying with tsinghua mirror")
                result = await runner.run(
                    venvPython,
                    arguments: baseArgs + ["--index-url", LocalRuntimeManager.tsinghuaMirror])
            }
            guard result.exitCode == 0 else {
                await MainActor.run { self?.fail("依赖安装失败：\(result.output.suffix(200))") }
                return
            }
            await MainActor.run { self?.phase = .installing(.verifying) }

            // 3. import 探针（sentencepiece 随 [stt] extra 安装，一并验证——
            //    缺它时 SenseVoice 家族静默吐 token ID，bug02）
            let probe = await runner.run(
                venvPython, arguments: ["-c", "import mlx_audio, sentencepiece"])
            guard probe.exitCode == 0 else {
                await MainActor.run { self?.fail("运行时自检失败：\(probe.output.suffix(200))") }
                return
            }

            let stamp = "\(LocalRuntimeManager.mlxAudioPin) ready at \(ISO8601DateFormatter().string(from: Date()))\n"
            // 真实 venv 必已建目录；防御兜底（Fake runner 场景/目录被手动清理）
            try? FileManager.default.createDirectory(at: venvURL, withIntermediateDirectories: true)
            try? stamp.write(to: readyMarker, atomically: true, encoding: .utf8)
            await MainActor.run {
                self?.phase = .ready
                AppLog.pipeline.notice("local ASR runtime ready (\(LocalRuntimeManager.mlxAudioPin, privacy: .public))")
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        AppLog.pipeline.error("local runtime install failed: \(message, privacy: .public)")
    }
}
