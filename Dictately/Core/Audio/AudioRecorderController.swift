import AVFoundation
import Foundation

/// 录音结果：落盘文件 URL + 毫秒时长（FR-002：停止回调返回 URL + 时长）。
struct AudioRecording: Equatable {
    let url: URL
    let durationMs: Int
}

/// 录音结束原因（PRD §11 录音表）：
/// - userStop：显式 stop()（热键停止/达逻辑终点）
/// - cancelled：Esc 取消（文件已删，调用方不得进入转写/入库）
/// - reachedMaxSeconds：达 maxRecordingSeconds 自动停（面板提示一次）
/// - deviceInterrupted：麦克风拔出/被独占（编码错误）→ 安全结束，保留部分音频
enum RecordingEndReason: Equatable {
    case userStop
    case cancelled
    case reachedMaxSeconds
    case deviceInterrupted
}

// MARK: - 协议层（可测性接缝）

/// 一次录音会话（真实实现 = AVAudioRecorder 薄封装；测试用假会话写可控 WAV）。
/// 协议只暴露控制器需要的最小面：录音控制 + 电平 + 错误回调。
protocol AudioRecordingSession: AnyObject {
    /// 开始录制（文件在 record 前已由 makeSession 关联）。
    func record() -> Bool
    /// 停止并封盘（补写 WAV 头部长度字段）；返回是否成功。
    @discardableResult
    func stop() -> Bool
    /// 已录秒数（AVAudioRecorder.currentTime 同义）。
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    /// 最近一次平均电平（dB，典型 -160…0）；不可用时 nil。
    /// 实现内部负责 updateMeters；控制器只按 30fps 轮询本方法。
    func currentAveragePower() -> Float?
    /// 编码/IO 错误回调（设备拔出/被独占）→ 控制器据此安全结束。
    var onEncodeError: (() -> Void)? { get set }
}

/// 录音设备工厂：按固定格式（Linear PCM/16kHz/单声道/16bit → .wav，PRD §2 已知坑 #5）
/// 创建写指定 URL 的会话。测试注入假工厂即可完全绕开真实麦克风。
protocol AudioRecorderDevice: AnyObject {
    func makeSession(url: URL) throws -> AudioRecordingSession
}

/// 音频会话激活器。**macOS 无 AVAudioSession**（iOS 概念）：AVAudioRecorder 在 macOS
/// 上开录即用，无需显式激活。保留此接缝是为了把「开始前激活/结束后去激活」的调用时序
/// 固化下来并可单测，同时为未来的独占模式/路由切换留扩展点；真实实现当前为带日志的空操作。
protocol AudioSessionActivator: AnyObject {
    func activate() throws
    func deactivate()
}

// MARK: - 真实实现

/// AVAudioRecorder 封装的真实设备（PRD §2 已知坑 #5 参数逐字）。
final class AVAudioRecorderDevice: AudioRecorderDevice {
    /// PRD §2 Stack Integration Guide #5 的录音格式字典（单测逐键断言）：
    /// Linear PCM / 16000Hz / 单声道 / 16bit 整数（小端），.wav 扩展名即输出 WAVE 容器。
    static let formatSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    func makeSession(url: URL) throws -> AudioRecordingSession {
        let recorder = try AVAudioRecorder(url: url, settings: Self.formatSettings)
        recorder.isMeteringEnabled = true // FR-002：供波形 averagePower
        return AVAudioRecorderSession(recorder: recorder)
    }
}

/// 单次会话封装：持有 AVAudioRecorder 与编码错误代理。
private final class AVAudioRecorderSession: NSObject, AudioRecordingSession {
    private let recorder: AVAudioRecorder
    private var errorDelegate: ErrorDelegate?
    var onEncodeError: (() -> Void)?

    init(recorder: AVAudioRecorder) {
        self.recorder = recorder
        super.init()
        let delegate = ErrorDelegate()
        delegate.onError = { [weak self] in self?.onEncodeError?() }
        self.errorDelegate = delegate
        self.recorder.delegate = delegate
    }

    func record() -> Bool { recorder.record() }
    func stop() -> Bool { recorder.stop(); return true }
    var currentTime: TimeInterval { recorder.currentTime }
    var isRecording: Bool { recorder.isRecording }

    func currentAveragePower() -> Float? {
        guard recorder.isRecording else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    /// AVAudioRecorderDelegate 只收编码错误（设备拔出/IO 异常），转成闭包回调。
    private final class ErrorDelegate: NSObject, AVAudioRecorderDelegate {
        var onError: (() -> Void)?
        func audioRecorderEncodeErrorDidOccur(
            _ recorder: AVAudioRecorder, error: Error?
        ) {
            AppLog.audio.error("recorder encode error: \(error.map(String.init(describing:)) ?? "<nil>", privacy: .public)")
            onError?()
        }
    }
}

/// macOS 上的会话激活器：如实空操作（见 AudioSessionActivator 注释）。
final class MacAudioSessionActivator: AudioSessionActivator {
    func activate() {
        AppLog.audio.debug("session activate (no-op on macOS; AVAudioRecorder self-managed)")
    }

    func deactivate() {
        AppLog.audio.debug("session deactivate (no-op on macOS; AVAudioRecorder self-managed)")
    }
}

// MARK: - 控制器

/// 录音控制器（FR-002）：开始（目标 <50ms）/停止返回 (URL, durationMs)/电平采样/达上限自动停。
///
/// 设计：AVAudioRecorder 全部经由 `AudioRecorderDevice` 协议访问，单测注入假设备——
/// 假会话写带正确 RIFF/fmt 头的 WAV，测试断言头字段与控制器行为；
/// 真实 1 秒录音需要麦克风权限（无头环境不可用），走 docs/dev-notes/phase1-manual-checks.md。
final class AudioRecorderController {
    /// 电平映射区间（FR-002）：-50dB→0，0dB→1（等比线性归一）。
    static let levelFloorDb: Float = -50

    /// 电平采样频率（FR-002 允许 10–60fps，取 30 与面板刷新率一致）。
    static let meteringInterval: TimeInterval = 1.0 / 30.0

    /// 录音完成回调（主线程之外可能来自编码错误路径，调用方自行切主线程）。
    var onFinish: ((AudioRecording, RecordingEndReason) -> Void)?

    private let device: AudioRecorderDevice
    private let sessionActivator: AudioSessionActivator
    /// 录音上限秒数（FR-002：达上限自动停止进入转写）。
    private let maxRecordingSeconds: () -> Int
    /// 目标文件 URL 提供者（默认临时目录；TASK-012 起由 AudioFileStore 提供命名）。
    private let makeFileURL: () -> URL

    private var session: AudioRecordingSession?
    private(set) var currentFileURL: URL?
    private(set) var isRecording = false
    /// 最新归一化电平（0…1，波形直接读取）；未录音为 nil。
    private(set) var currentLevel: Float?
    private var meteringTimer: Timer?
    /// finish 串行化锁：主 RunLoop 计时器（startMetering）与调用方线程可并发进入收口。
    private let finishLock = NSLock()

    /// - Parameters:
    ///   - device: 录音设备（测试注入假设备）
    ///   - sessionActivator: 会话激活/去激活时序接缝
    ///   - maxRecordingSeconds: 上限秒数读取器（生产传 `{ settings.maxRecordingSeconds }`）
    ///   - makeFileURL: 目标 WAV 文件 URL（生产默认 NSTemporaryDirectory 下的临时名）
    init(
        device: AudioRecorderDevice = AVAudioRecorderDevice(),
        sessionActivator: AudioSessionActivator = MacAudioSessionActivator(),
        maxRecordingSeconds: @escaping () -> Int = { 240 },
        makeFileURL: (() -> URL)? = nil
    ) {
        self.device = device
        self.sessionActivator = sessionActivator
        self.maxRecordingSeconds = maxRecordingSeconds
        if let makeFileURL {
            self.makeFileURL = makeFileURL
        } else {
            self.makeFileURL = {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("rec-\(UUID().uuidString).wav")
            }
        }
    }

    deinit {
        meteringTimer?.invalidate()
    }

    // MARK: - 开始/停止

    /// 开始录音。抛错场景：会话激活失败/设备创建失败（AVAudioRecorder 初始化抛 Error）。
    /// 启动路径只做：激活 → 建会话 → record()，不等待任何 IO，目标 <50ms（FR-002）。
    func start() throws {
        guard !isRecording else { return }
        let url = makeFileURL()
        try sessionActivator.activate()
        let session = try device.makeSession(url: url)
        session.onEncodeError = { [weak self] in
            // PRD §11：麦克风拔出/被独占 → 安全结束，已录部分照常可转写
            DispatchQueue.main.async { self?.finish(reason: .deviceInterrupted) }
        }
        guard session.record() else {
            // AVAudioRecorder.record() 返回 false（无权限/设备忙）：收拾干净再抛
            sessionActivator.deactivate()
            throw AudioRecorderError.startFailed
        }
        self.session = session
        currentFileURL = url
        isRecording = true
        currentLevel = 0
        AppLog.audio.notice("recording started → \(url.lastPathComponent, privacy: .public)")
        startMetering()
    }

    /// 停止录音并返回结果；未在录音时返回 nil（幂等，不抛错）。
    @discardableResult
    func stop() -> AudioRecording? {
        finish(reason: .userStop)
    }

    /// 取消录音：停止且**不保留**文件（Esc 取消链路：停录+删临时音频，FR-006）。
    /// onFinish 以 .cancelled 回调——调用方据此只做清理，不进转写不入库。
    func cancel() {
        guard isRecording, let url = currentFileURL else { return }
        finish(reason: .cancelled)
        try? FileManager.default.removeItem(at: url)
        AppLog.audio.notice("recording cancelled, temp file removed")
    }

    /// 归一化电平映射（纯函数，单测覆盖）：-50dB 以下→0，0dB→1，区间内线性。
    static func normalizedLevel(fromDecibels db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let clamped = min(max(db, levelFloorDb), 0)
        return (clamped - levelFloorDb) / -levelFloorDb
    }

    // MARK: - 内部

    /// 统一收尾：停会话 → 去激活 → 停采样 → 回调。
    /// 来源三路：stop()（userStop）/上限自动停（meteringTick）/编码错误（deviceInterrupted）。
    /// 2026-10-07 竞态修复：三路可并发（计时器在主 RunLoop，调用方/编码错误在其他线程），
    /// 原先第二路会撞 `currentFileURL!`（swift test 2/3 复现的崩溃）——锁内完成全部状态
    /// 收尾串行化，后进者看到 isRecording==false 按幂等语义返回 nil；onFinish 移出锁外
    /// （finishLock 非重入，回调链内的同步 stop/cancel/meteringTick 不得持锁重入）。
    @discardableResult
    private func finish(reason: RecordingEndReason) -> AudioRecording? {
        finishLock.lock()
        var recording: AudioRecording?
        if isRecording, let session {
            let durationMs = max(0, Int((session.currentTime * 1000).rounded()))
            session.stop()
            sessionActivator.deactivate()
            stopMetering()
            isRecording = false
            currentLevel = nil
            self.session = nil
            // start() 时序保证 isRecording==true 时 currentFileURL 已就位，强解包安全
            recording = AudioRecording(url: currentFileURL!, durationMs: durationMs)
            currentFileURL = nil
            AppLog.audio.notice(
                "recording finished reason=\(String(describing: reason), privacy: .public) duration=\(durationMs, privacy: .public)ms")
        }
        finishLock.unlock()
        if let recording {
            onFinish?(recording, reason)
        }
        return recording
    }

    /// 启动主线程电平采样定时器（30fps）；真实 UI 场景用，测试直接调 meteringTick()。
    private func startMetering() {
        let timer = Timer(timeInterval: Self.meteringInterval, repeats: true) { [weak self] _ in
            self?.meteringTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        meteringTimer = timer
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    /// 一次采样：读电平 → 归一化存 currentLevel；并检查录音上限（FR-002 自动停止）。
    /// 单测显式调用本方法驱动（无 runloop 依赖）。
    func meteringTick() {
        guard isRecording, let session else { return }
        if let db = session.currentAveragePower() {
            currentLevel = Self.normalizedLevel(fromDecibels: db)
        }
        let maxMs = Double(max(0, maxRecordingSeconds())) * 1000
        if session.currentTime * 1000 >= maxMs {
            finish(reason: .reachedMaxSeconds)
        }
    }
}

/// 录音错误（TASK-011 范围仅启动失败；设备/权限细分错误随 TASK-016 ASRError 统一映射）。
enum AudioRecorderError: Error, Equatable {
    /// record() 返回 false：无权限/设备忙/格式不可写。
    case startFailed
}
