import AVFoundation
import CoreAudio

// MARK: - WAV 写入（纯逻辑，单测直接覆盖）

/// Linear PCM WAV 文件写入器（16kHz/单声道/16bit 小端，PRD §2 录音格式）。
/// 逐段追加 PCM 数据，`finish()` 补写 RIFF 头（长度字段按实际数据计算）。
/// 线程模型：append（tap 线程）与 byteCount（metering 线程）由持有方加锁串行。
struct WAVFileWriter {
    let url: URL
    let sampleRate: Int
    let channels: Int
    private(set) var pcmData: [UInt8] = []

    init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// 已累积 PCM 字节数（currentTime 推导用：16kHz/mono/16bit = 32000 字节每秒）。
    var byteCount: Int { pcmData.count }

    /// 追加交错 16bit PCM（小端）。
    mutating func append(int16 samples: [Int16]) {
        pcmData.reserveCapacity(pcmData.count + samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            pcmData.append(UInt8(value & 0xFF))
            pcmData.append(UInt8(value >> 8))
        }
    }

    /// 落盘：44 字节标准头 + 数据。返回是否成功。
    mutating func finish() -> Bool {
        let header = Self.header(dataBytes: pcmData.count, sampleRate: sampleRate, channels: channels)
        var bytes = header
        bytes.append(contentsOf: pcmData)
        do {
            try Data(bytes).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.audio.error("wav write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 标准 PCM WAV 头（RIFF/fmt/data；16bit）。逐字节确定性，单测锁定。
    static func header(dataBytes: Int, sampleRate: Int, channels: Int) -> [UInt8] {
        let byteRate = sampleRate * channels * 2
        func le32(_ v: Int) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        var h: [UInt8] = []
        h += Array("RIFF".utf8)
        h += le32(36 + dataBytes)          // ChunkSize
        h += Array("WAVE".utf8)
        h += Array("fmt ".utf8)
        h += le32(16)                      // Subchunk1Size (PCM)
        h += le16(1)                       // AudioFormat = PCM
        h += le16(channels)
        h += le32(sampleRate)
        h += le32(byteRate)
        h += le16(channels * 2)            // BlockAlign
        h += le16(16)                      // BitsPerSample
        h += Array("data".utf8)
        h += le32(dataBytes)
        return h
    }
}

// MARK: - 麦克风选择（纯解析逻辑 + AVCaptureDevice 适配）

/// 麦克风选择解析结果：设备在列表中 → 用所选；不在（已拔出）→ 回退默认。
struct MicrophoneSelection {
    struct Device: Equatable {
        let uid: String
        let name: String
    }

    /// 纯函数（单测覆盖）：preferredUID 空 → 默认不提示；
    /// 非空且命中 → 所选；非空未命中 → 默认 + fellBack（设置页提示一次，FR-015）。
    static func resolve(preferredUID: String, devices: [Device])
        -> (device: Device?, fellBack: Bool) {
        guard !preferredUID.isEmpty else { return (nil, false) }
        if let hit = devices.first(where: { $0.uid == preferredUID }) {
            return (hit, false)
        }
        return (nil, true)
    }
}

/// AVCaptureDevice 查询（唯一触碰真实硬件的薄层）。
enum MicrophoneList {
    /// 内置 + 外接麦克风（uniqueID 用于设备选择）。
    static func availableDevices() -> [MicrophoneSelection.Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio, position: .unspecified
        )
        return session.devices.map {
            MicrophoneSelection.Device(uid: $0.uniqueID, name: $0.localizedName)
        }
    }
}

// MARK: - AVAudioEngine 录音会话（设备选择真实生效的路径，TASK-039）

/// 经 AVAudioEngine 输入的录音设备：支持按 AVCaptureDevice.uniqueID 选定麦克风
/// （经输入节点 HAL 单元 kAudioOutputUnitProperty_CurrentDevice 设置——macOS 上
/// AVAudioRecorder 无设备选择 API，此为公开途径）。所选设备失效 → 回退系统默认
/// 并回调 `onFallbackToDefault`（设置页「提示一次」）。
final class AVAudioEngineDevice: AudioRecorderDevice {
    /// 每次录音现读（设置改动即时生效）；空 = 默认设备。
    let preferredDeviceUID: () -> String?
    /// 回退发生时回调（UID 已失效）。
    var onFallbackToDefault: ((String) -> Void)?

    init(preferredDeviceUID: @escaping () -> String?) {
        self.preferredDeviceUID = preferredDeviceUID
    }

    func makeSession(url: URL) throws -> AudioRecordingSession {
        AVAudioEngineRecordingSession(
            url: url,
            preferredDeviceUID: preferredDeviceUID(),
            onFallback: { [onFallbackToDefault] failedUID in
                onFallbackToDefault?(failedUID)
            })
    }
}

/// 单次录音会话：engine 输入 tap → AVAudioConverter（16kHz/单声道/Int16）→ 内存累积 →
/// stop() 写 WAV。电平取 tap 帧 RMS（dB）。设备拔出（配置变化通知）→ onEncodeError
/// （控制器走 deviceInterrupted 安全结束，保留部分音频，PRD §11）。
final class AVAudioEngineRecordingSession: NSObject, AudioRecordingSession {
    private let url: URL
    private let engine = AVAudioEngine()
    /// tap 线程写、metering 线程读——pcmData/字节计数经此锁串行。
    private let dataLock = NSLock()
    private var writer: WAVFileWriter
    private var converter: AVAudioConverter?
    private var lastPowerDb: Float?
    private var recording = false
    private var configurationObserver: NSObjectProtocol?

    /// 自愈进行中标记（ConfigurationChange 重入守卫）。
    private var recovering = false

    var onEncodeError: (() -> Void)?

    init(url: URL, preferredDeviceUID: String?, onFallback: @escaping (String) -> Void) {
        self.url = url
        self.writer = WAVFileWriter(url: url)
        super.init()
        applyDeviceSelection(preferredUID: preferredDeviceUID, onFallback: onFallback)
        observeConfigurationChange()
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 录前应用设备选择：命中 → 设到输入节点 HAL 单元；未命中/设置失败 → 默认 + 回调。
    private func applyDeviceSelection(preferredUID: String?, onFallback: (String) -> Void) {
        guard let uid = preferredUID, !uid.isEmpty else { return }
        guard let deviceID = Self.audioDeviceID(uid: uid) else {
            AppLog.audio.notice("preferred mic missing, falling back to default (uid=\(uid, privacy: .public))")
            onFallback(uid)
            return
        }
        let input = engine.inputNode // 首访问即 attach，audioUnit 此后可用
        guard let audioUnit = input.audioUnit else {
            AppLog.audio.error("input node audioUnit unavailable, using default")
            onFallback(uid)
            return
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 1, &mutableID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            AppLog.audio.error("mic device set failed (\(status)), using default")
            onFallback(uid)
        }
    }

    /// UID → CoreAudio AudioDeviceID（kAudioHardwarePropertyTranslateUIDToDevice，文档途径）。
    static func audioDeviceID(uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let status = withUnsafePointer(to: cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &id) { idPtr in
                AudioObjectGetPropertyData(
                    systemObject, &address,
                    UInt32(MemoryLayout<CFString>.size), uidPtr, &size, idPtr)
            }
        }
        return status == noErr ? id : nil
    }

    private func observeConfigurationChange() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // 设备拔出/系统路由变化：先自愈（重启输入），失败才按设备中断收尾（bug00016）
            guard let self, self.recording else { return }
            self.recoverOrInterrupt()
        }
    }

    /// 路由变化（蓝牙模式切换/默认设备变化）先自愈后中断：拆 tap → 按当前格式重建 →
    /// 重启 engine；成功继续录（已录字节保留），失败走 onEncodeError（controller 的
    /// deviceInterrupted 安全结束语义不变，PRD §11）。重入守卫：自愈过程中的再次
    /// 通知不叠加处理。
    private func recoverOrInterrupt() {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        if startOrRestartInput() {
            AppLog.audio.notice("input route changed — engine restarted, recording continues")
        } else {
            // 保持 recording=true 走 controller 常规 finish（session.stop 落盘部分音频）
            AppLog.audio.error("input restart failed after route change — device interrupted")
            onEncodeError?()
        }
    }

    // MARK: - AudioRecordingSession

    var currentTime: TimeInterval {
        dataLock.lock()
        defer { dataLock.unlock() }
        return Double(writer.byteCount) / 32_000.0
    }

    var isRecording: Bool { recording }

    func record() -> Bool {
        // 必须读 AVAudioApplication（TASK-121）：旧 AVCaptureDevice.authorizationStatus
        // 在「用户刚在弹框里点允许」后不随进程内状态即时翻转（仍 notDetermined），
        // 首装授权当次开录必被本闸门误拒；与管道闸门/PermissionChecker 保持同源。
        guard AVAudioApplication.shared.recordPermission == .granted else { return false }
        guard startOrRestartInput() else { return false }
        recording = true
        return true
    }

    /// 按输入节点当前格式（重）建 tap + converter 并启动 engine。
    /// 首次启动与路由变化自愈共用——重启时按新设备格式重建，旧 converter 失配即弃。
    private func startOrRestartInput() -> Bool {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return false }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AppLog.audio.error("engine start failed: \(String(describing: error), privacy: .public)")
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    @discardableResult
    func stop() -> Bool {
        guard recording else { return false }
        recording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        dataLock.lock()
        defer { dataLock.unlock() }
        return writer.finish()
    }

    func currentAveragePower() -> Float? {
        guard recording else { return nil }
        return lastPowerDb
    }

    // MARK: - tap 处理（engine 工作线程回调）

    private func process(buffer: AVAudioPCMBuffer) {
        lastPowerDb = Self.powerDb(buffer: buffer)
        guard let converter else { return }
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        // 输入块只交一次数据，之后 .noDataNow——否则 converter 会重复拉同一 buffer。
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { return }

        if let channel = out.int16ChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            dataLock.lock()
            writer.append(int16: samples)
            dataLock.unlock()
        }
    }

    /// 帧 RMS → dB（与 AVAudioRecorder averagePower 同量纲：满幅 0，静音 -160）。
    static func powerDb(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let v = channel[i]
            sum += v * v
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
