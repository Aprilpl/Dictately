import AppKit
import Foundation

/// 面板呈现抽象：Pipeline 依赖此协议而非 NSPanel（单测注入假面板断言调用序）。
/// 真实实现 = RecordingPanelController（conformance 在 UI/Panel/RecordingPanelController.swift
/// 文件末尾——Core 文件不写 UI 类型的 extension，TASK-114）。
protocol PanelPresenting: AnyObject {
    func warmUp()
    func showPanel()
    func hidePanel()
}

/// 历史条目重试模式（TASK-034 / FR-012/013）。
enum EntryRetryMode {
    /// 重跑 ASR→（风格）→粘贴，原地更新。
    case full
    /// 重跑后仅复制（不粘贴）。
    case copyOnly
    /// 仅重跑 LLM 润色段（failed 且 raw 非空的 style 条目）。
    case polishOnly
}

/// 全链路服务束（TASK-019）：Pipeline 完成录音后的 转写→输出→入库 段所需依赖。
/// nil 时 Pipeline 保持 TASK-015 骨架行为（直接收尾，便于分层测试）。
struct DictationServices {
    let asrEngine: ASREngine
    let llmEngine: LLMEngine
    let clipboard: ClipboardService
    let pasteInjector: PasteInjector
    let entries: EntryRepository
    let styles: StyleRepository
    let audioStore: AudioFileStore
    /// Key 存储（TASK-048：SecretStore 协议 + 缓存包装；禁止逐听写触达底层）。
    let secrets: SecretStore
    /// 声音反馈（TASK-041）：录音开始/结束短音，受 soundEffects 开关控制。
    let sounds: SoundFeedback
    /// 时钟注入（入库 createdAt 与测试）。
    var now: () -> Date = { Date() }
}

/// 听写编排器（FR-006）——TASK-019 起为全链路：
///
/// 状态：idle → recording →（停止）transcribing →（ASR 成功）done/cancelled；
/// 取消：recording → cancelled → idle（停录 + 删临时文件 + 面板淡出 + 不入库）。
/// services == nil 时退化为录音段骨架（TASK-015 行为，测试兼容）。
final class DictationPipeline {
    let panelModel: RecordingPanelModel

    private let recorder: AudioRecorderController
    private let panel: PanelPresenting
    private let settings: AppSettings
    private let phaseTimer: PhaseTimer
    /// 录音时静音（TASK-074）：开录成功后压掉系统声音，收口在 onFinish 单一漏斗恢复。
    private let audioMuter: SystemAudioMuting

    /// 麦克风授权请求接缝（TASK-106 开录闸门；真实实现 AVAudioApplication，测试桩替换）。
    private let micPermission: MicrophonePermissionRequesting
    /// 全链路服务（nil = 骨架行为；AppEnvironment 生产装配必传）。
    private let services: DictationServices?

    /// 失败上下文（TASK-020 面板/历史重试的输入）。
    struct FailureContext: Equatable {
        enum Stage: Equatable {
            case asr(ASRError)
            case polish(LLMError) // US-004：润色失败已回退粘贴原文，可「重试润色」（TASK-029）
            case paste
        }
        let recording: AudioRecording
        let stage: Stage
        /// 关联的失败条目 id（重试成功/失败后原地更新，FR-013）。
        let entryID: Int64?
    }
    private(set) var lastFailure: FailureContext?

    /// holdOrToggle 语义：本次录音是否由「当前按住手势」启动。
    /// .tapCompleted 到达时：true → 保持录音（切换开）；false → 停止（切换关）。
    private var recordingInitiatedByPress = false

    /// 误触守卫阈值：短于此毫秒数的录音视为误触直接丢弃（不入库、不送转写）。
    /// 最短语音（单音节）≈200ms+，300ms 给出裕量；toggle 模式双击的第二击
    /// 落在 ~100-200ms，落不到任何真实语音。
    static let minDictationMs: Int = 300

    /// 效果音预滚兜底超时（TASK-075）：播放完成回调万一不达（异常设备态），
    /// 到时照样开录——提示音不可用不能挡听写。测试可注入更短值。
    var soundCueTimeout: TimeInterval = 2

    /// 预滚世代 token：完成回调 / 兜底超时 / 取消三路都可能触发收口，
    /// 每次进入预滚自增，收口前双检防双触发与陈旧回调串扰。
    private var cueGeneration = 0

    /// 本次听写绑定的风格（nil = 普通听写）；风格热键启动时设置。
    private(set) var currentStyle: Style?
    private var escMonitor: Any?
    private var chainTask: Task<Void, Never>?
    /// 当前链路对应的录音（粘贴失败上下文恢复用）。
    private var chainRecording: AudioRecording?

    init(
        recorder: AudioRecorderController,
        panel: PanelPresenting,
        panelModel: RecordingPanelModel = RecordingPanelModel(),
        settings: AppSettings,
        phaseTimer: PhaseTimer = PhaseTimer(),
        audioMuter: SystemAudioMuting = SystemAudioMuter(),
        micPermission: MicrophonePermissionRequesting = SystemMicrophonePermissionRequester(),
        services: DictationServices? = nil
    ) {
        self.recorder = recorder
        self.panel = panel
        self.panelModel = panelModel
        self.settings = settings
        self.phaseTimer = phaseTimer
        self.audioMuter = audioMuter
        self.micPermission = micPermission
        self.services = services

        // 录音结束的单一路径：无论停止/上限/中断/取消，都经 onFinish 汇总处理
        recorder.onFinish = { [weak self] recording, reason in
            let deliver: () -> Void = { self?.handleRecordingFinished(recording, reason: reason) }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
    }

    /// 面板预创建（App 启动时调用；NSPanel 常驻避免首唤起创建开销）。
    func warmUp() {
        panel.warmUp()
    }

    /// 当前链路阶段（面板状态机的别名）。
    var phase: PanelPhase { panelModel.phase }

    // MARK: - 热键事件入口（主线程）

    func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .start:
            if panelModel.phase == .idle {
                beginDictation(triggeredByPress: true)
            } else {
                // 按下未开启新录音（录音中/处理中叠加按下）：
                // 标记本手势非启动手势，让随后的 .tapCompleted 正确解释为「切换关」
                recordingInitiatedByPress = false
            }
        case .toggleStart:
            switch panelModel.phase {
            case .idle: beginDictation(triggeredByPress: false)
            case .recording: stopDictation()
            default: break // 处理中再翻转：忽略（PRD §11「忽略重启」）
            }
        case .stop:
            if panelModel.phase == .recording { stopDictation() }
        case .tapCompleted:
            // 由本按下启动 → 保持（切换开）；按下时已在录 → 停止（切换关）
            if panelModel.phase == .recording && !recordingInitiatedByPress {
                stopDictation()
            }
        }
    }

    // MARK: - 取消（Esc / 编程入口）

    /// 全局 Esc 入口（HotkeyEngine tap 捕获）：设置开启 + 录音中/预滚中才生效（FR-003）。
    func handleEscape() {
        guard settings.escCancelsRecording,
              panelModel.phase == .recording || panelModel.phase == .cueing else { return }
        cancel()
    }

    /// 取消当前听写：停录 + 删临时音频 + 面板淡出 + 不入库（FR-006/PRD §11）。
    /// cueing 态取消（TASK-075）：尚未开录、无文件可清——失效预滚世代并直接淡出。
    func cancel() {
        guard panelModel.phase == .recording || panelModel.phase == .cueing else { return }
        removeEscMonitor()
        if panelModel.phase == .recording {
            recorder.cancel() // 结果经 onFinish(.cancelled) 回调收尾
        } else {
            cueGeneration += 1 // 播完回调/兜底超时到来时世代已变，不再开录
            panelModel.enterCancelled()
            finishAndHidePanel()
        }
    }

    // MARK: - 录音段

    /// 开录入口（TASK-075「先播音后开录」用户裁决；同日追裁「准备中」时长减半）：
    /// 效果音开且服务在 → **预滚**——面板即现进 cueing 态（保 FR-003 热键→面板 <100ms
    /// 预算），播所选效果音**至半程**（播放失败 / 兜底超时同样）再实际开录，停声先于
    /// engine 启动、无尾音灌麦；否则（开关关 / 骨架模式）零延迟直开。播音先于 engine
    /// 启动——bug00016 的「录音启动窗口不做音频输出动作」防复发铁律由顺序倒转天然
    /// 满足（自愈机制保留双保险）。
    private func beginDictation(triggeredByPress: Bool, style: Style? = nil) {
        guard panelModel.phase == .idle else { return }
        phaseTimer.reset()
        phaseTimer.begin(.hotkeyToPanel) // 热键回调进入点（引擎队列→主线程的跳数不计）
        currentStyle = style

        guard let sounds = services?.sounds, settings.soundEffects else {
            startRecordingAfterCue(triggeredByPress: triggeredByPress)
            return
        }

        cueGeneration += 1
        let generation = cueGeneration
        panelModel.enterCueing(style: style?.name, escEnabled: settings.escCancelsRecording)
        panel.showPanel()
        phaseTimer.end(.hotkeyToPanel)
        installEscMonitor() // 预滚期间 Esc 即可取消（面板可见，提示键帽同步展示）

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.cueGeneration == generation, self.panelModel.phase == .cueing else { return }
            AppLog.audio.notice("sound cue timed out — starting recording anyway")
            self.startRecordingAfterCue(triggeredByPress: triggeredByPress)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + soundCueTimeout, execute: timeout)

        sounds.playStartCue { [weak self] played in
            timeout.cancel()
            guard let self, self.cueGeneration == generation, self.panelModel.phase == .cueing else { return }
            if !played {
                AppLog.audio.notice("sound cue failed to play — starting recording anyway")
            }
            self.startRecordingAfterCue(triggeredByPress: triggeredByPress)
        }
    }

    /// 实际开录段（预滚 completion 与零延迟直开共用）。
    /// 录音时静音（TASK-074）在开录成功后执行——提示音先于静音播放、可闻；
    /// 结束音在 restore 之后播放、可闻。
    private func startRecordingAfterCue(triggeredByPress: Bool) {
        let cameFromCue = panelModel.phase == .cueing
        guard cameFromCue || panelModel.phase == .idle else { return }

        // 麦克风授权闸门（TASK-106）：「未决定」态先发系统询问再开录——否则
        // AVAudioEngineRecorder.record 的 authorized 前置会拒绝启动且弹窗永不出现
        // （新装机/权限重置后「无法开始录音」死锁根因）。询问期间面板维持现状，
        // 裁决后主线程续跑（弹窗期间已取消 → 主体重验阶段自然放弃）。
        guard micPermission.needsRequest else {
            startRecordingBody(triggeredByPress: triggeredByPress, cameFromCue: cameFromCue)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.micPermission.request()
            AppLog.pipeline.notice(
                "microphone permission request granted=\(granted, privacy: .public)")
            guard granted else {
                AppLog.pipeline.error("recorder start skipped — microphone permission denied")
                self.failStart(cameFromCue: cameFromCue, permissionIssue: true)
                return
            }
            self.startRecordingBody(triggeredByPress: triggeredByPress, cameFromCue: cameFromCue)
        }
    }

    /// 开录主体（授权闸门通过后）。授权弹窗期间状态可能已被取消——重验阶段再启动。
    private func startRecordingBody(triggeredByPress: Bool, cameFromCue: Bool) {
        guard cameFromCue ? panelModel.phase == .cueing : panelModel.phase == .idle else { return }
        do {
            try recorder.start()
        } catch {
            // 启动失败（无权限/设备忙）：失败态可见，不静默（PRD §11 权限表 P0）
            AppLog.pipeline.error("recorder start failed: \(String(describing: error), privacy: .public)")
            failStart(cameFromCue: cameFromCue, permissionIssue: micPermission.isDenied)
            return
        }

        panelModel.enterRecording(style: currentStyle?.name, escEnabled: settings.escCancelsRecording)
        if !cameFromCue {
            panel.showPanel()
            phaseTimer.end(.hotkeyToPanel)
            installEscMonitor()
        }
        phaseTimer.begin(.record)
        recordingInitiatedByPress = triggeredByPress
        if settings.muteDuringRecording {
            audioMuter.mute()
        }
        AppLog.pipeline.notice("dictation started")
    }

    /// 开录失败收口（启动抛错 / 授权被拒共用）：失败横幅可见不静默 + 计时收尾。
    /// permissionIssue（TASK-107，FR-019）：HUD 失败横幅据此显示「去授权」按钮。
    private func failStart(cameFromCue: Bool, permissionIssue: Bool = false) {
        panelModel.enterFailed(
            String(localized: "panel.failed.recording"), permissionIssue: permissionIssue)
        if !cameFromCue {
            panel.showPanel()
            phaseTimer.end(.hotkeyToPanel)
        }
        phaseTimer.finish()
        scheduleFailedPanelAutoDismiss()
    }

    private func stopDictation() {
        guard panelModel.phase == .recording else { return }
        _ = recorder.stop() // 结果经 onFinish 单一路径回调
    }

    // MARK: - 风格热键（可自定义组合，FR-008/裁决 #12；引擎 StyleHotkeyEvent → 这里）

    /// 模式三选语义（TASK-071，settings.styleHotkeyMode 全局）：按住 → start/stop
    /// 成对；切换/双击 → toggleStart 翻转。未绑定/停用的组合静默忽略（日志可查）。
    /// 录音中异风格触发 / 处理中触发：忽略（对齐录音 toggleStart 的 PRD §11「忽略重启」）。
    func handleStyleHotkey(_ event: StyleHotkeyEvent) {
        switch event {
        case .start(let combo):
            guard panelModel.phase == .idle else { return }
            beginStyledDictation(combo, triggeredByPress: true)
        case .stop(let combo):
            if panelModel.phase == .recording, currentStyle?.hotkeyCombo == combo.storageString {
                stopDictation()
            }
        case .toggleStart(let combo):
            switch panelModel.phase {
            case .idle:
                beginStyledDictation(combo, triggeredByPress: false)
            case .recording:
                if currentStyle?.hotkeyCombo == combo.storageString {
                    stopDictation()
                }
            default: break // 处理中再翻转：忽略
            }
        }
    }

    /// 风格热键开始听写：解析绑定（未绑定/停用静默忽略）→ 带风格徽标开录。
    private func beginStyledDictation(_ combo: HotkeyCombo, triggeredByPress: Bool) {
        guard let services else { return }
        guard let style = (try? services.styles.fetchByHotkey(combo.storageString)) ?? nil else {
            AppLog.hotkey.notice("style hotkey \(combo.displayText, privacy: .public) unbound or disabled — ignored")
            return
        }
        beginDictation(triggeredByPress: triggeredByPress, style: style)
    }

    /// 录音结束统一收口（onFinish 派发到主线程后调用）。
    private func handleRecordingFinished(_ recording: AudioRecording, reason: RecordingEndReason) {
        // 录音时静音的恢复点：停止/上限/中断/取消/误触守卫全部经此漏斗，
        // 先恢复声音再走各分支（结束提示音因此可闻）；未亲手静音则空操作。
        audioMuter.restore()
        removeEscMonitor()
        recordingInitiatedByPress = false
        phaseTimer.end(.record)

        switch reason {
        case .cancelled:
            // 取消链路：临时文件已由 recorder 删除；不入库（TASK-019 起取消条目也不入库）
            panelModel.enterCancelled()
            finishAndHidePanel()

        case .userStop, .reachedMaxSeconds, .deviceInterrupted:
            // 误触守卫（2026-10-01 排查：toggle 模式下双击手势 = 一击启动 + 二击即停，
            // 产出 0 帧 44 字节空 WAV，送转写必被服务端 4xx 拒绝，面板弹「请求被拒绝」）。
            // <300ms 不可能含语音 → 按取消语义静默收口：不入库、不送网络、清临时文件。
            if recording.durationMs < Self.minDictationMs {
                AppLog.pipeline.notice(
                    "recording too short (\(recording.durationMs, privacy: .public)ms) — discarded as accidental")
                try? FileManager.default.removeItem(at: recording.url)
                panelModel.enterCancelled()
                finishAndHidePanel()
                return
            }
            // TASK-041：结束短音只在正常收口响（取消=用户已按键知情；设备中断=异常路径）
            if reason != .deviceInterrupted {
                services?.sounds.recordingStopped()
            }
            // 停止 → 转写态；services 非空走全链路（TASK-019），否则骨架收尾
            guard panelModel.enterTranscribing() else {
                finishAndHidePanel()
                return
            }
            if let services {
                processFullChain(recording, services: services, style: currentStyle)
            } else {
                // 骨架（services == nil，测试兼容）：无转写段直接收尾；
                // 音频保留在录音目录，由孤儿恢复机制兜底转写入库（TASK-036）。
                finishAndHidePanel()
            }
        }
    }

    // MARK: - 网络类错误自动重试（TASK-042 / FR-006：立即重试一次，无退避）
    // 与手动重试区分：手动入口（面板重试/历史重试）走既有 retryFromFailure/retryEntry
    // 并各自记日志；此处自动重试日志统一带「auto-retry 1/1」字样。

    /// ASR 转写 + 网络类错误自动重试一次（networkUnreachable/timeout；其余错误直接抛）。
    private static func transcribeWithAutoRetry(
        _ engine: ASREngine, audioFileAt url: URL, config: ASRConfig,
        timer: PhaseTimer
    ) async throws -> ASRTranscript {
        do {
            return try await engine.transcribe(audioFileAt: url, config: config)
        } catch let error as ASRError where error.isNetworkError {
            AppLog.pipeline.notice("asr network error (\(error.localizedDescription, privacy: .public)), auto-retry 1/1 (no backoff)")
            timer.end(.asr)
            timer.begin(.asr) // 重试计为新一段 asr
            return try await engine.transcribe(audioFileAt: url, config: config)
        }
    }

    /// LLM 润色 + 网络类错误自动重试一次。
    private static func polishWithAutoRetry(
        _ executor: StyleExecutor, rawText: String, style: Style, config: LLMConfig,
        timer: PhaseTimer
    ) async throws -> LLMResult {
        do {
            return try await executor.polish(rawText: rawText, style: style, config: config)
        } catch let error as LLMError where error.isNetworkError {
            AppLog.pipeline.notice("llm network error (\(error.localizedDescription, privacy: .public)), auto-retry 1/1 (no backoff)")
            timer.end(.llm)
            timer.begin(.llm)
            return try await executor.polish(rawText: rawText, style: style, config: config)
        }
    }

    // MARK: - 全链路（TASK-019：录音 → ASR → 剪贴板/粘贴 → 入库）

    /// 转写与输出段。主线程发起；ASR/入库在后台执行；面板状态回写切主线程。
    /// - Parameter entryID: 重试时传原条目 id（结果更新该行）；首次传 nil（新插入）。
    ///
    /// 段拆分（TASK-116）：润色/输出/入库三段提取为下方私有方法（显式参数进出），
    /// 本方法只做编排与收尾分派；段内行为与拆分前逐行等价。
    private func processFullChain(
        _ recording: AudioRecording, services: DictationServices,
        entryID: Int64? = nil, style: Style? = nil, pasteEnabled: Bool = true
    ) {
        chainRecording = recording
        let config = ASRConfig.live(settings: settings, secrets: services.secrets)
        let llmConfig = LLMConfig.live(settings: settings, secrets: services.secrets)
        // 主线程快照设置（AppSettings 非线程安全）
        let autoCopy = settings.autoCopyClipboard
        let timer = phaseTimer

        chainTask = Task.detached { [weak self] in
            // strong ref：链路执行期间持有 self（有界——chainTask 完成即释放）
            guard let self else { return }
            // encode 阶段折叠于客户端内部（Base64 在请求前完成），计时以 asr 覆盖
            timer.begin(.asr)
            do {
                let transcript = try await Self.transcribeWithAutoRetry(
                    services.asrEngine, audioFileAt: recording.url, config: config, timer: timer)
                timer.end(.asr)

                // 润色 → 输出 → 入库：返回值均为不可变绑定（并发闭包禁捕获 var）
                let polish = await self.runPolishPass(
                    rawText: transcript.text, style: style, services: services,
                    config: llmConfig, timer: timer)
                let output = self.deliverOutput(
                    text: polish.text, autoCopy: autoCopy, pasteEnabled: pasteEnabled,
                    services: services, timer: timer)
                let successEntryID = self.persistSuccessEntry(
                    transcript: transcript, recording: recording, services: services,
                    entryID: entryID, style: style, config: config,
                    finalText: polish.text, llmModel: polish.llmModel, llmLatencyMs: polish.llmLatencyMs,
                    polishError: polish.polishError, pasted: output.pasted)

                await MainActor.run {
                    if let polishFailure = polish.polishError {
                        self.finishPolishFailure(recording: recording, error: polishFailure, entryID: successEntryID)
                    } else {
                        self.finishSuccess(pasteFailed: output.pasteFailed, entryID: successEntryID)
                    }
                }
            } catch let error as ASRError {
                timer.end(.asr)
                // 失败入库：音频保留、错误分类齐全（FR-006「任意阶段抛错 → 统一失败处理」）
                let failureEntryID = self.persistFailedEntry(
                    recording: recording, services: services,
                    entryID: entryID, error: error, config: config)
                await MainActor.run { self.finishASRFailure(recording: recording, error: error, entryID: failureEntryID) }
            } catch {
                timer.end(.asr)
                AppLog.pipeline.error("unexpected chain error: \(String(describing: error), privacy: .public)")
                await MainActor.run { self.finishASRFailure(recording: recording, error: .badResponse, entryID: entryID) }
            }
        }
    }

    /// 润色段（FR-008/US-004）：面板进入「润色中 · x.xs」；LLM 失败 → 回退粘贴原始转写
    /// （finalText = rawText，条目 failed，可重试润色）。无风格时原样透传（finalText = rawText）。
    private func runPolishPass(
        rawText: String, style: Style?, services: DictationServices,
        config: LLMConfig, timer: PhaseTimer
    ) async -> (text: String, llmModel: String?, llmLatencyMs: Int?, polishError: LLMError?) {
        var finalText = rawText
        var llmModel: String?
        var llmLatencyMs: Int?
        var polishError: LLMError?
        if let style {
            timer.begin(.llm)
            await MainActor.run { _ = self.panelModel.enterPolishing() }
            do {
                let executor = StyleExecutor(engine: services.llmEngine)
                let polished = try await Self.polishWithAutoRetry(
                    executor, rawText: rawText, style: style, config: config, timer: timer)
                finalText = polished.text
                llmModel = polished.model
                llmLatencyMs = polished.latencyMs
            } catch let error as LLMError {
                polishError = error
            } catch {
                polishError = .badResponse
            }
            timer.end(.llm)
        }
        return (finalText, llmModel, llmLatencyMs, polishError)
    }

    /// 输出段：剪贴板（autoCopy）→ 合成 ⌘V（FR-005）。粘贴失败退化为「已复制」
    /// （US-002 edge：文本在剪贴板，pasted=0），由调用方决定是否进 paste 失败态。
    private func deliverOutput(
        text: String, autoCopy: Bool, pasteEnabled: Bool,
        services: DictationServices, timer: PhaseTimer
    ) -> (pasted: Bool, pasteFailed: Bool) {
        if autoCopy { services.clipboard.write(text) }
        timer.begin(.paste)
        var pasted = false
        var pasteFailed = false
        if pasteEnabled {
            do {
                try services.pasteInjector.paste()
                pasted = true
            } catch {
                pasteFailed = true
            }
        }
        timer.end(.paste)
        return (pasted, pasteFailed)
    }

    /// 入库段（成功侧；润色失败也走这里——status=.failed + 错误分类、finalText=原文回退，
    /// 收尾分派在调用方）。重试更新原行（FR-013：重试更新状态、清空错误）；首次插入新行。
    private func persistSuccessEntry(
        transcript: ASRTranscript, recording: AudioRecording, services: DictationServices,
        entryID: Int64?, style: Style?, config: ASRConfig,
        finalText: String, llmModel: String?, llmLatencyMs: Int?,
        polishError: LLMError?, pasted: Bool
    ) -> Int64? {
        var successEntryIDBox = entryID
        let entryStatus: Entry.Status = polishError == nil ? .success : .failed
        let kindKey = polishError?.kindKey
        let userMessage = polishError?.userMessage
        if let entryID, var original = try? services.entries.fetch(id: entryID) {
            original.status = entryStatus
            original.errorKind = kindKey
            original.errorMessage = userMessage
            original.rawText = transcript.text
            original.finalText = finalText
            original.asrModel = config.model
            original.asrLatencyMs = transcript.latencyMs
            original.llmModel = llmModel
            original.llmLatencyMs = llmLatencyMs
            original.pasted = pasted
            _ = try? services.entries.update(original)
            AppLog.pipeline.notice("entry #\(entryID, privacy: .public) retry-\(entryStatus == .success ? "success" : "polish-failed", privacy: .public) \(PhaseTimer.textDigest(finalText), privacy: .public) pasted=\(pasted, privacy: .public)")
        } else {
            let entry = Entry(
                createdAt: services.now().timeIntervalSince1970,
                type: style == nil ? .dictation : .style,
                styleId: style?.id,
                status: entryStatus,
                errorKind: kindKey,
                errorMessage: userMessage,
                audioPath: recording.url.lastPathComponent,
                audioDurationMs: recording.durationMs,
                rawText: transcript.text,
                finalText: finalText,
                asrModel: config.model,
                asrLatencyMs: transcript.latencyMs,
                llmModel: llmModel,
                llmLatencyMs: llmLatencyMs,
                pasted: pasted
            )
            if let inserted = try? services.entries.insert(entry) {
                successEntryIDBox = inserted.id
                AppLog.pipeline.notice("entry #\(inserted.id.map(String.init) ?? "?", privacy: .public) \(entryStatus == .success ? "success" : "polish-fallback", privacy: .public) \(PhaseTimer.textDigest(finalText), privacy: .public) pasted=\(pasted, privacy: .public)")
            }
        }
        return successEntryIDBox
    }

    /// 入库段（ASR 失败侧）：音频保留、错误分类齐全；重试更新原行，首次插入新行。
    private func persistFailedEntry(
        recording: AudioRecording, services: DictationServices,
        entryID: Int64?, error: ASRError, config: ASRConfig
    ) -> Int64? {
        let entry = Entry(
            createdAt: services.now().timeIntervalSince1970,
            type: .dictation,
            status: .failed,
            errorKind: error.kindKey,
            errorMessage: error.userMessage,
            audioPath: recording.url.lastPathComponent,
            audioDurationMs: recording.durationMs,
            asrModel: config.model
        )
        var failureEntryID = entryID
        if let entryID, var original = try? services.entries.fetch(id: entryID) {
            original.status = .failed
            original.errorKind = error.kindKey
            original.errorMessage = error.userMessage
            _ = try? services.entries.update(original)
        } else if let inserted = try? services.entries.insert(entry) {
            failureEntryID = inserted.id
        }
        AppLog.pipeline.notice("entry failed kind=\(error.kindKey, privacy: .public) audio=\(recording.url.lastPathComponent, privacy: .public)")
        return failureEntryID
    }

    /// 成功收尾：正常路径 done + 300ms 淡出；粘贴失败退化为失败态提示
    /// （US-002 edge：文本已复制，pasted=0；「重试」仅重发粘贴——见 retryFromFailure）。
    private func finishSuccess(pasteFailed: Bool, entryID: Int64?) {
        completeEntryRetry()
        if pasteFailed {
            let recording = chainRecording ?? AudioRecording(url: URL(fileURLWithPath: ""), durationMs: 0)
            lastFailure = FailureContext(recording: recording, stage: .paste, entryID: entryID)
            panelModel.enterFailed(String(localized: "panel.pasted.fallback", bundle: AppResources.bundle))
            phaseTimer.finish()
            scheduleFailedPanelAutoDismiss()
        } else {
            lastFailure = nil
            panelModel.enterDone()
            finishAndHidePanel(delay: PanelVisibilityPolicy.doneAutoHideDelay)
        }
    }

    /// 润色失败收尾（US-004）：原文已粘贴（回退成功时），面板提示原因 + 重试润色入口（TASK-029）。
    private func finishPolishFailure(recording: AudioRecording, error: LLMError, entryID: Int64?) {
        completeEntryRetry()
        lastFailure = FailureContext(recording: recording, stage: .polish(error), entryID: entryID)
        let message = String(format: String(localized: "panel.failed.polish", bundle: AppResources.bundle), error.userMessage)
        panelModel.enterFailed(message)
        phaseTimer.finish()
    }

    /// 转写失败收尾：失败态停留可交互（重试/关闭）。
    private func finishASRFailure(recording: AudioRecording, error: ASRError, entryID: Int64?) {
        completeEntryRetry()
        lastFailure = FailureContext(recording: recording, stage: .asr(error), entryID: entryID)
        let message = String(format: String(localized: "panel.failed.template", bundle: AppResources.bundle), error.userMessage)
        panelModel.enterFailed(message)
        phaseTimer.finish()
    }

    /// 失败面板的「关闭」动作（panelController.onClose 接线）。
    func closeFailedPanel() {
        guard case .failed = panelModel.phase else { return }
        lastFailure = nil
        panel.hidePanel()
        panelModel.reset()
        currentStyle = nil
    }

    /// 历史条目重试入口（TASK-034）：详情页「重试/重试并复制/重试润色」接线。
    /// 面板进入转写/润色态展示进度；完成（成功或失败收尾）后回调 completion（主线程）。
    func retryEntry(id: Int64, mode: EntryRetryMode, completion: (() -> Void)? = nil) {
        guard let services else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        switch mode {
        case .full, .copyOnly:
            guard let entry = try? services.entries.fetch(id: id),
                  let path = entry.audioPath,
                  let url = services.audioStore.resolve(path: path),
                  FileManager.default.fileExists(atPath: url.path) else {
                AppLog.pipeline.notice("retry entry #\(id, privacy: .public): audio missing — refused")
                completion.map { DispatchQueue.main.async(execute: $0) }
                return
            }
            let style: Style? = entry.type == .style
                ? (entry.styleId.flatMap { (try? services.styles.fetch(id: $0)) ?? nil })
                : nil
            guard panelModel.enterTranscribing() else {
                completion.map { DispatchQueue.main.async(execute: $0) }
                return
            }
            onEntryRetryCompletion = completion
            let recording = AudioRecording(url: url, durationMs: entry.audioDurationMs ?? 0)
            processFullChain(recording, services: services, entryID: id, style: style,
                             pasteEnabled: mode == .full)
        case .polishOnly:
            guard let entry = try? services.entries.fetch(id: id),
                  let rawText = entry.rawText, !rawText.isEmpty,
                  panelModel.enterPolishing() else {
                completion.map { DispatchQueue.main.async(execute: $0) }
                return
            }
            onEntryRetryCompletion = completion
            let recording = entry.audioPath
                .flatMap { services.audioStore.resolve(path: $0) }
                .map { AudioRecording(url: $0, durationMs: entry.audioDurationMs ?? 0) }
            rerunPolish(entryID: id, rawText: rawText, recording: recording)
        }
    }

    /// 条目重试完成回调（链路各收尾处触发，主线程）。
    private var onEntryRetryCompletion: (() -> Void)? {
        get { _onEntryRetryCompletion }
        set { _onEntryRetryCompletion = newValue }
    }
    private var _onEntryRetryCompletion: (() -> Void)?

    /// 统一触发重试完成回调并清空。
    private func completeEntryRetry() {
        let handler = _onEntryRetryCompletion
        _onEntryRetryCompletion = nil
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    /// 失败面板的「重试」动作（FR-013 面板内手动重试；自动重试一次是 Phase 4 TASK-043）。
    /// - asr 失败：用已落盘音频重跑 ASR→输出段，结果更新原条目；
    /// - paste 失败：仅重发合成 ⌘V，成功则回写 pasted=1。
    /// 重试前面板回 transcribing 态（粘贴重试除外——无网络段）。
    func retryFromFailure() {
        guard case .failed = panelModel.phase, let failure = lastFailure else { return }

        switch failure.stage {
        case .asr:
            guard panelModel.enterTranscribing() else { return }
            processFullChain(failure.recording, services: services!, entryID: failure.entryID)
        case .polish:
            retryPolishOnly(failure: failure)
        case .paste:
            retryPasteOnly(entryID: failure.entryID)
        }
    }

    /// 仅重试润色（TASK-029 / FR-012）：failed 且 raw 非空的 style 条目只重跑 LLM 段，
    /// 原地更新 final/status/错误/LLM 计时；成功后重新走剪贴板+粘贴输出。
    private func retryPolishOnly(failure: FailureContext) {
        guard let services, let entryID = failure.entryID,
              let entry = try? services.entries.fetch(id: entryID),
              entry.type == .style,
              let rawText = entry.rawText, !rawText.isEmpty else {
            // 降级兜底：条目信息不完整 → 整链重跑（音频路径仍在）
            guard let services, panelModel.enterTranscribing() else { return }
            processFullChain(failure.recording, services: services, entryID: failure.entryID, style: currentStyle)
            return
        }
        _ = panelModel.enterPolishing() // failed → polishing（重试润色路径）
        rerunPolish(entryID: entryID, rawText: rawText, recording: failure.recording)
    }

    /// 仅重跑 LLM 段核心（面板重试与历史「重试润色」共用）。
    private func rerunPolish(entryID: Int64, rawText: String, recording: AudioRecording?) {
        guard let services else { completeEntryRetry(); return }
        let style = currentStyle ?? resolvedStyle(entryID: entryID)
        guard let style else {
            // 风格已被删：无法仅重跑润色 → 兜底整链（若有音频）或直接收尾
            if let recording, panelModel.enterTranscribing() {
                processFullChain(recording, services: services, entryID: entryID)
            } else {
                completeEntryRetry()
            }
            return
        }
        let llmConfig = LLMConfig.live(settings: settings, secrets: services.secrets)
        let autoCopy = settings.autoCopyClipboard
        let timer = phaseTimer

        chainTask = Task.detached { [weak self] in
            guard let self else { return }
            timer.begin(.llm)
            let outcome: Result<LLMResult, LLMError>
            do {
                let executor = StyleExecutor(engine: services.llmEngine)
                let result = try await Self.polishWithAutoRetry(
                    executor, rawText: rawText, style: style, config: llmConfig, timer: timer)
                outcome = .success(result)
            } catch let error as LLMError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.badResponse)
            }
            timer.end(.llm)

            switch outcome {
            case .success(let polished):
                // 输出段复用全链路拆段件（TASK-116）。重跑路径的粘贴失败按既定语义吞掉：
                // 只影响条目 pasted 位，不进 paste 失败态（历史「重新生成」粘贴是附带动作，
                // 文本已在剪贴板）——故收尾恒走 finishSuccess(pasteFailed: false)。
                let output = self.deliverOutput(
                    text: polished.text, autoCopy: autoCopy, pasteEnabled: true,
                    services: services, timer: timer)

                if var updated = try? services.entries.fetch(id: entryID) {
                    updated.status = .success
                    updated.errorKind = nil
                    updated.errorMessage = nil
                    updated.finalText = polished.text
                    updated.llmModel = polished.model
                    updated.llmLatencyMs = polished.latencyMs
                    updated.pasted = output.pasted
                    _ = try? services.entries.update(updated)
                }
                AppLog.pipeline.notice("entry #\(entryID, privacy: .public) retry-polish success \(PhaseTimer.textDigest(polished.text), privacy: .public)")
                await MainActor.run {
                    self.finishSuccess(pasteFailed: false, entryID: entryID)
                }
            case .failure(let error):
                if var updated = try? services.entries.fetch(id: entryID) {
                    updated.status = .failed
                    updated.errorKind = error.kindKey
                    updated.errorMessage = error.userMessage
                    _ = try? services.entries.update(updated)
                }
                AppLog.pipeline.notice("entry #\(entryID, privacy: .public) retry-polish failed kind=\(error.kindKey, privacy: .public)")
                await MainActor.run {
                    // 收尾复用润色失败漏斗（TASK-116）；recording 可空 → 空占位与拆段前一致
                    self.finishPolishFailure(
                        recording: recording ?? AudioRecording(url: URL(fileURLWithPath: ""), durationMs: 0),
                        error: error, entryID: entryID)
                }
            }
        }
    }

    /// 条目关联的风格解析（styleId → 当前风格；被删则 nil → 兜底整链）。
    private func resolvedStyle(entryID: Int64) -> Style? {
        guard let services,
              let entry = try? services.entries.fetch(id: entryID),
              let styleId = entry.styleId else { return nil }
        return (try? services.styles.fetch(id: styleId)) ?? nil
    }

    /// 仅重试粘贴：文本已在剪贴板（US-002 降级前提），重发 ⌘V 成功则更新 pasted。
    private func retryPasteOnly(entryID: Int64?) {
        guard let services else { return }
        phaseTimer.begin(.paste)
        do {
            try services.pasteInjector.paste()
            phaseTimer.end(.paste)
            lastFailure = nil
            if let entryID, var original = try? services.entries.fetch(id: entryID) {
                original.pasted = true
                _ = try? services.entries.update(original)
            }
            // 粘贴已生效（文字就位）——直接淡出收尾，无需 done 态展示
            panel.hidePanel()
            panelModel.reset()
            phaseTimer.finish()
            finishAndHidePanel(delay: PanelVisibilityPolicy.doneAutoHideDelay)
            AppLog.pipeline.notice("paste retry success")
        } catch {
            phaseTimer.end(.paste)
            panelModel.enterFailed(String(localized: "panel.pasted.fallback", bundle: AppResources.bundle))
            phaseTimer.finish()
            AppLog.pipeline.notice("paste retry failed again")
        }
    }

    /// 收尾：计时汇总落日志 → 面板淡出 → 状态回 idle。
    /// 成功态的 300ms 延迟自动隐藏（FR-003）由 TASK-019 的成功路径调用带 delay 版本。
    /// 延迟分支闭包必须复查 phase：窗口内已开新一轮时（paste 重试路径先 reset 回 idle、
    /// 用户随即再触发热键），迟到的收尾不得隐藏新 HUD、重置状态或清 currentStyle
    /// （对照失败路径 scheduleFailedPanelAutoDismiss 的同款守卫；终态含 .idle——
    /// retryPasteOnly 本就先 reset 后挂延迟收尾）。
    private func finishAndHidePanel(delay: TimeInterval = 0) {
        phaseTimer.finish()
        let hide = { [weak self] in
            self?.panel.hidePanel()
            self?.panelModel.reset()
            self?.currentStyle = nil
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                switch self.panelModel.phase {
                case .done, .failed, .cancelled, .idle:
                    hide()
                case .cueing, .recording, .transcribing, .polishing:
                    break // 窗口内已开新一轮：迟到的收尾作废
                }
            }
        } else {
            hide()
        }
    }

    // MARK: - Esc 本地捕获（面板显示期间）

    /// Esc 监听（PRD FR-003 / roadmap TASK-015）：面板期间 NSEvent local monitor
    /// 捕获 keyDown 53（kVK_Escape）并吞掉。面板以 nonactivating key 呈现（TASK-013），
    /// 用户按 Esc 时事件进入本 App → 本 monitor 可见；受 `escCancelsRecording` 控制。
    private func installEscMonitor() {
        guard settings.escCancelsRecording, escMonitor == nil, NSApp != nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // kVK_Escape
            self.cancel()
            return nil // 吞掉：Esc 不再传给面板内容
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    /// 录音启动失败面板的兜底自动隐藏（骨架：无重试动作，4s 后淡出；
    /// TASK-020 起失败态由用户操作关闭）。
    private func scheduleFailedPanelAutoDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.panelModel.phase != .idle, self.panelModel.phase != .recording else { return }
            self.panel.hidePanel()
            self.panelModel.reset()
        }
    }
}
