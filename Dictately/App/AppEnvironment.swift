import SwiftUI

/// 依赖容器（PRD §2 Repository Structure：App/AppEnvironment.swift）。
/// 集中装配 settings/secrets(SecretStore)/database/entryRepository/styleRepository 及
/// TASK-011~015 起的核心链路服务（audioStore/recorder/panel/pipeline/hotkeyEngine）；
/// UI 统一通过 `@Environment(AppEnvironment.self)` 取用，避免散落单例。
@Observable
final class AppEnvironment {
    let settings: AppSettings
    /// Key 存储（TASK-048：协议化 + 读穿透缓存；Release 恒 Keychain，Debug 可 env 旁路）。
    let secrets: SecretStore
    let database: AppDatabase
    let entryRepository: EntryRepository
    let styleRepository: StyleRepository
    /// 权限检测（TASK-009）：init 即读一次真实系统状态（只读不弹窗）。
    let permissions: PermissionChecker

    // MARK: - 核心听写链路（TASK-011~015）

    /// 录音文件目录管理（TASK-012）。
    let audioStore: AudioFileStore
    /// 录音控制器（TASK-011）：目标文件名由 audioStore 提供（rec-{ISO8601}.wav）。
    let recorder: AudioRecorderController
    /// 面板状态源（TASK-013）：Pipeline 与面板视图共用。
    let panelModel = RecordingPanelModel()
    /// NSPanel 呈现（TASK-013）：NSPanel 懒创建，启动时 warmUp() 预创建常驻。
    let panelController: RecordingPanelController
    /// 听写编排器（TASK-015 骨架：录音段）。
    let pipeline: DictationPipeline
    /// 热键引擎（TASK-014）：right ⌘ listen-only tap。
    let hotkeyEngine: HotkeyEngine
    /// 转写引擎（TASK-016 起协议化；2026-10-01 起为路由引擎：按 settings.asrProvider
    /// 分流 qwen=QwenASRClient / openai+groq+custom=OpenAICompatibleASRClient，业务层无感）。
    let asrEngine: ASREngine
    /// LLM 引擎（TASK-023）：OpenAI 兼容客户端（润色/测试连接）。
    let llmEngine: OpenAICompatibleClient
    /// 共享剪贴板服务（Pipeline 输出 + 历史/详情「复制」）。
    let clipboard = ClipboardService()
    /// 主窗口路由（TASK-076）：⌘, / 状态栏菜单统一入口，主窗口关闭后仍能重开。
    let windowRouter = WindowRouter()
    /// 全站动作 Toast（TASK-097）：复制/重新生成等操作反馈，主窗口底部居中。
    let toast = ToastPresenter()

    /// 指定初始化器（全量注入；测试与预览用内存库走这里）。
    init(settings: AppSettings, secrets: SecretStore, database: AppDatabase) {
        self.settings = settings
        self.secrets = secrets
        self.database = database
        self.entryRepository = EntryRepository(database: database)
        self.styleRepository = StyleRepository(database: database)
        // 内置风格首启种子（FR-009 幂等：表非空即跳过）；失败不阻断启动
        do {
            if try styleRepository.seedBuiltinsIfEmpty() {
                AppLog.db.notice("builtin styles seeded (意图识别 ⌘1 / 口语润色 ⌘2 / 中英互译 ⌘3)")
            }
            // 老库内置行 description 回填（bug00008/00009：UI 从 tags 切到 description 列）
            if try styleRepository.backfillBuiltinDescriptions() {
                AppLog.db.notice("builtin style descriptions backfilled")
            }
            // 内置排序迁移（用户裁决：意图识别在上）
            if try styleRepository.reorderBuiltinStylesIntentFirst() {
                AppLog.db.notice("builtin styles reordered (intent first)")
            }
            // 槽位整数 → 组合串迁移（裁决 #12：存量 hotkey=1/2 原样搬为 "cmd+18"/"cmd+19"）
            if try styleRepository.backfillHotkeyCombos() {
                AppLog.db.notice("style hotkey combos backfilled (slot ints → combo strings)")
            }
            // 第三内置风格补种（2026-10-02：老库只增不改；⌘+3 被占用则不抢绑）
            if try styleRepository.insertMissingBuiltinTranslate() {
                AppLog.db.notice("builtin translate style inserted (中英互译 ⌘3)")
            }
        } catch {
            AppLog.db.error("builtin style seed failed: \(String(describing: error), privacy: .public)")
        }
        self.permissions = PermissionChecker()

        // 录音存储：默认目录失败（磁盘满等）逐级回退，App 保持可用
        self.audioStore = Self.makeAudioStore()

        // 录音控制器：上限/命名均从 store 与 settings 现读（设置改动即时生效）；
        // 麦克风选择（TASK-039/FR-015）：AVAudioEngine 输入按 uniqueID 选设备，
        // 失效回退系统默认并标记「提示一次」（设置页展示后清除）
        let store = audioStore
        let micDevice = AVAudioEngineDevice(
            preferredDeviceUID: { [weak settings] in settings?.micDeviceUID ?? "" })
        micDevice.onFallbackToDefault = { [weak settings] failedUID in
            settings?.micFallbackNoticePending = true
            AppLog.audio.notice("selected mic unavailable, fell back to default (uid=\(failedUID, privacy: .public))")
        }
        self.recorder = AudioRecorderController(
            device: micDevice,
            maxRecordingSeconds: { [weak settings] in settings?.maxRecordingSeconds ?? 240 },
            makeFileURL: { store.makeRecordingURL() }
        )

        // ASR 引擎先于 pipeline 初始化（全链路服务引用它）
        self.asrEngine = RoutingASREngine()
        self.llmEngine = OpenAICompatibleClient()

        let panelModel = self.panelModel
        self.panelController = RecordingPanelController(model: panelModel)
        self.pipeline = DictationPipeline(
            recorder: recorder,
            panel: panelController,
            panelModel: panelModel,
            settings: settings,
            services: DictationServices(
                asrEngine: asrEngine,
                llmEngine: llmEngine,
                clipboard: clipboard,
                pasteInjector: PasteInjector(),
                entries: entryRepository,
                styles: styleRepository,
                audioStore: audioStore,
                secrets: secrets,
                sounds: SoundFeedback(
                    isEnabled: { [weak settings] in settings?.soundEffects ?? true },
                    effectProvider: { [weak settings] in settings?.soundEffect ?? .defaultSound })
            )
        )
        // 失败面板动作（TASK-020：重试/关闭）
        let pipelineCloseRef = pipeline
        panelController.onClose = { pipelineCloseRef.closeFailedPanel() }
        panelController.onRetry = { [weak pipelineCloseRef] in pipelineCloseRef?.retryFromFailure() }
        // 波形电平：面板 30fps 采样透传到 recorder 最新电平
        let recorderRef = recorder
        panelController.levelSampler = { [weak recorderRef] in recorderRef?.currentLevel }

        // 音频保留清理（FR-018/TASK-035）：audioStore 就绪后后台执行，只删文件不动行
        Self.scheduleAudioRetentionCleanup(settings: settings, entries: entryRepository, audioStore: audioStore)

        self.hotkeyEngine = HotkeyEngine(
            modeProvider: { [weak settings] in
                settings?.hotkeyMode ?? .doubleTap
            },
            triggerProvider: { [weak settings] in
                settings?.recordingHotkeyCombo ?? .defaultTrigger
            },
            styleModeProvider: { [weak settings] in
                settings?.styleHotkeyMode ?? .toggle
            }
        )
        // 热键事件：引擎后台队列 → 主线程进 Pipeline
        let pipelineRef = pipeline
        hotkeyEngine.onEvent = { event in
            DispatchQueue.main.async { pipelineRef.handleHotkeyEvent(event) }
        }
        // 全局 Esc（面板显示期间任意 App 下取消录音，FR-003）
        hotkeyEngine.onEscape = {
            DispatchQueue.main.async { pipelineRef.handleEscape() }
        }
        // 风格热键（FR-008/裁决 #12：可自定义组合）
        hotkeyEngine.onStyleEvent = { event in
            DispatchQueue.main.async { pipelineRef.handleStyleHotkey(event) }
        }
        // 引擎绑定集：启动推入一次 + styles 任一写操作后重算
        // （「是否吞事件」的判定依据，裁决 #12）
        refreshStyleHotkeyBindings()
        stylesChangeObserver = NotificationCenter.default.addObserver(
            forName: StyleRepository.didChangeNotification, object: styleRepository, queue: nil
        ) { [weak self] _ in
            self?.refreshStyleHotkeyBindings()
        }
    }

    deinit {
        if let stylesChangeObserver {
            NotificationCenter.default.removeObserver(stylesChangeObserver)
        }
    }

    /// 重算启用风格的组合集推入引擎（吞事件判定用；后台读库不阻塞调用方）。
    /// 无效存储串（手改库等）静默忽略——不吞、不响应，UI 按未绑定显示。
    func refreshStyleHotkeyBindings() {
        let repo = styleRepository
        let engine = hotkeyEngine
        Task.detached(priority: .utility) {
            let styles = (try? repo.fetchAll()) ?? []
            let combos = Set(
                styles.filter(\.enabled).compactMap {
                    $0.hotkeyCombo.flatMap(HotkeyCombo.init(storageString:))
                })
            engine.refreshBindings(combos)
        }
    }

    /// styles 变更观察（StyleRepository.didChangeNotification；deinit 移除）。
    private var stylesChangeObserver: NSObjectProtocol?

    /// 生产装配：默认库 `~/Library/Application Support/Dictately/dictately.sqlite`。
    /// 库打不开时按 PRD §11 存储异常兜底降级内存库 + error 日志，App 保持可用
    /// （库损坏备份重建的完整处理后续阶段补）。
    convenience init() {
        self.init(settings: AppSettings(), secrets: Self.makeDefaultSecretStore()) {
            try AppDatabase.openDefault()
        }
    }

    /// SecretStore 生产装配（TASK-048）：统一包 `CachingSecretStore`——每账户每进程
    /// 至多一次底层读（AGENTS.md 硬约束 #1）。Debug 裸跑旁路：`DICTATELY_DEV_SECRETS=1`
    /// 时走 `FileSecretStore`（明文 0600，仅开发自用）；Release 恒 Keychain（硬约束 #2）。
    static func makeDefaultSecretStore() -> SecretStore {
        #if DEBUG
        if Self.isDevSecretsBypassEnabled, let file = try? FileSecretStore() {
            AppLog.pipeline.notice("dev secrets bypass active (FileSecretStore, DICTATELY_DEV_SECRETS=1)")
            return CachingSecretStore(underlying: file)
        }
        #endif
        return CachingSecretStore(underlying: KeychainStore())
    }

    /// 启动预热全部 Key 账户入缓存（硬约束 #1「启动读一次」的完整落地）：
    /// 后台读，避免 Keychain ACL 授权（开发期裸跑场景）阻塞启动主线程；
    /// 就绪后设置页 onAppear / 首次听写全部命中缓存，零现场 Keychain 访问。
    func prefetchSecrets() {
        guard let caching = secrets as? CachingSecretStore else { return }
        // 听写五账户（2026-10-04 增 Mistral）+ AI 服务七账户（2026-10-02 两级页分存；DeepSeek 复用旧全局账户）
        let accounts = [SecretAccount.asrAPIKey, SecretAccount.asrAPIKeyOpenAI,
                        SecretAccount.asrAPIKeyGroq, SecretAccount.asrAPIKeyMistral,
                        SecretAccount.asrAPIKeyCustom]
            + AppSettings.LLMProvider.allCases.map(SecretAccount.llmAccount(for:))
        Task.detached(priority: .utility) {
            caching.prefetch(accounts)
        }
    }

    #if DEBUG
    /// Debug 旁路开关判定（TASK-048 层 C；静态属性便于单测 setenv/unsetenv）。
    static var isDevSecretsBypassEnabled: Bool {
        ProcessInfo.processInfo.environment["DICTATELY_DEV_SECRETS"] == "1"
    }
    #endif

    /// 以可替换的开库函数装配（生产传默认开库；失败降级内存库）。
    /// AppDatabase 打开成功时自记一条 notice 级 db 日志——初始化恰好一次，
    /// 满足「日志可见各服务初始化一次」的可观测性。
    convenience init(
        settings: AppSettings, secrets: SecretStore,
        openDatabase: () throws -> AppDatabase
    ) {
        let db: AppDatabase
        do {
            db = try openDatabase()
        } catch {
            // PRD §11：存储异常不阻断 App；Phase 0 简化为内存库降级。
            do {
                db = try AppDatabase(path: nil) // 内存库无 IO，正常不会失败
            } catch {
                fatalError("in-memory database unavailable: \(error)") // 不可恢复的编程错误
            }
        }
        self.init(settings: settings, secrets: secrets, database: db)
    }

    /// 后台清理过期音频：retentionDays=0 永久保留跳过；失败仅日志。
    private static func scheduleAudioRetentionCleanup(
        settings: AppSettings, entries: EntryRepository, audioStore: AudioFileStore
    ) {
        let days = settings.audioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        Task.detached {
            do {
                let stale = try entries.audioPathsOfStaleSuccessEntries(olderThan: cutoff)
                guard !stale.isEmpty else { return }
                let removed = audioStore.cleanupExpiredAudio(paths: stale)
                AppLog.audio.notice("retention cleanup: \(removed.count, privacy: .public) expired audio files removed (retention=\(days, privacy: .public)d)")
            } catch {
                AppLog.audio.error("retention cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 录音目录逐级回退：默认（~/Library/.../Recordings）→ 临时目录子目录 → 临时目录。
    /// 最后一级的目录本身必然存在（系统临时目录），createDirectory 不会失败。
    private static func makeAudioStore() -> AudioFileStore {
        do {
            return try AudioFileStore()
        } catch {
            AppLog.audio.error("recordings store init failed, falling back to temp: \(String(describing: error), privacy: .public)")
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictately-Recordings", isDirectory: true)
        do {
            return try AudioFileStore(directory: fallback)
        } catch {
            AppLog.audio.error("temp recordings store also failed: \(String(describing: error), privacy: .public)")
            return try! AudioFileStore(directory: FileManager.default.temporaryDirectory)
        }
    }
}
