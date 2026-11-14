import Foundation
import Observation

// MARK: - 控制器

/// 文件转写控制器（TASK-150，方案 D）：AppEnvironment 级持有——切页/关窗不中断转写；
/// 页面视图仅绑定状态。串行队列逐文件转写（本地显存/API 限流皆宜串行），单文件
/// 失败不阻断后续。
///
/// 线程模型沿 DictationPipeline 惯例：可变状态**仅主线程读写**（@Observable 无隔离
/// 强制，纪律约定）；后台批次在 Task.detached 执行（文件 IO/DB/引擎调用），状态
/// 回写一律 `await MainActor.run`。
///
/// 进度为**分段真进度**（TASK-151 统一切片管线）：文件先经 AudioImportService
/// 统一转 16k WAV 分段，逐段转写，进度 = 已完成段/总段数；ETA 由已测单片均值×
/// 剩余段实时更新。侧栏徽标总进度 = (已完成数 + 当前进度) / 总数。
@Observable
final class FileTranscribeController {
    // MARK: 依赖

    let settingsRef: AppSettings
    let secrets: SecretStore
    let repository: FileTranscriptRepository
    let audioStore: AudioFileStore
    let apiEngine: ASREngine
    let localEngineFactory: (String) -> ASREngine
    let llmEngine: LLMEngine
    let toast: ToastPresenter
    /// 本地模型已下载判定（菜单 dim 与开始门槛）。
    let isLocalModelInstalled: (String) -> Bool
    /// 分段目标段长（秒；TASK-151 统一切片管线。参数化供测试注入）。
    let segmentSeconds: Double

    // MARK: 页面状态（方案 D 状态机：empty/picked/running/done + hist = viewingEntryID 非 nil）

    enum Phase: Equatable {
        case empty, picked, running, done
    }

    private(set) var phase: Phase = .empty
    private(set) var pendingFiles: [PendingTranscribeFile] = []
    private(set) var selection: TranscribeModelSelection
    /// 运行队列（running 态渲染源；顺序 = 开始时的文件顺序）。
    var queueItems: [TranscribeQueueItem] = []
    /// done 态批次结果（按队列顺序的落库行快照）。
    var batchResults: [FileTranscript] = []
    /// hist 态：右栏点入的历史条目 id（nil = 非查看态）。
    var viewingEntryID: Int64?
    /// hist 态左栏详情（全行，含 text/summary——列表源只存轻量列，TASK-158；
    /// selectHistoryEntry 后台拉取，回填前 nil = 加载占位）。总结/重试完成时刷新。
    var viewingDetail: FileTranscript?
    /// 历史重试进行中的条目 id（hist 态左栏显示进度卡，原型 h._run）。
    var retryingEntryID: Int64?
    var retryProgress: Double = 0
    var retryElapsedSeconds: Double = 0
    var retryStartedAt: Date?

    /// 历史列表（右栏渲染源；倒序；轻量行——大列详情走 viewingDetail，TASK-158）。
    /// 分页（TASK-185）：只持已加载页，滚动到底加载下一页。
    var history: [FileTranscriptListItem] = []
    /// 历史总条数（面板标题「x 条」与 hasMore 判定）。
    var historyTotalCount = 0
    var historyHasMore = false
    var isLoadingMoreHistory = false
    static let historyPageSize = 50
    var historyLoadMoreTask: Task<Void, Never>?

    /// AI 总结进行中的条目 id 集合（按钮三态：未总结/正在总结…/已总结=summary 非空）。
    var summarizingIDs: Set<Int64> = []

    /// 批次起止（done 头「用时」）。
    private var batchStartedAt: Date?
    private(set) var batchElapsedSeconds: Double = 0

    /// 各队列条目已用秒（旁路字典：ticker 每 1s 只写它，queueItems 不随之失效——
    /// ETA 文本叶子视图单独读取，整页/侧栏徽标不再每秒重算，TASK-158）。
    private(set) var itemElapsedSeconds: [UUID: Double] = [:]

    private var queueTask: Task<Void, Never>?
    /// 批次是否在跑（TASK-173：reset / 历史点选的主线程守卫源——批次运行期间
    /// 任何清空 `queueItems` 的操作都会让后台循环失去状态锚点。startTranscription
    /// 置 true，finishBatch 收口置 false；取消路径同样经 finishBatch 收口）。
    private(set) var isBatchRunning = false
    var retryTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    var historyReloadTask: Task<Void, Never>?
    var historyReloadGeneration = 0
    private var bootstrapped = false
    /// RootView 注入（Toast 抑制判据：在转写页时完成不弹——页面本身即反馈）。
    var isOnTranscribePage: (() -> Bool)?

    // MARK: 装配

    init(
        settings: AppSettings,
        secrets: SecretStore,
        repository: FileTranscriptRepository,
        audioStore: AudioFileStore,
        apiEngine: ASREngine,
        localEngineFactory: @escaping (String) -> ASREngine,
        llmEngine: LLMEngine,
        toast: ToastPresenter,
        isLocalModelInstalled: @escaping (String) -> Bool,
        segmentSeconds: Double = 180
    ) {
        self.settingsRef = settings
        self.secrets = secrets
        self.repository = repository
        self.audioStore = audioStore
        self.apiEngine = apiEngine
        self.localEngineFactory = localEngineFactory
        self.llmEngine = llmEngine
        self.toast = toast
        self.isLocalModelInstalled = isLocalModelInstalled
        self.segmentSeconds = segmentSeconds
        self.selection = .current(settings: settings)
    }

    /// 启动收口：上次退出遗留的 running 行归一为中断失败 + 拉取历史（幂等）。
    func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let repository = self.repository
        Task.detached(priority: .utility) {
            let interrupted = (try? repository.markInterrupted()) ?? 0
            if interrupted > 0 {
                AppLog.pipeline.notice("file transcripts interrupted rows normalized: \(interrupted, privacy: .public)")
            }
        }
        reloadHistory()
    }

    // MARK: 导入（拖放 / fileImporter 入口；主线程）

    /// 过滤白名单并入列（按标准化路径去重）；存在不合格式时 Toast 提示并返回 false。
    @discardableResult
    func addFileURLs(_ urls: [URL]) -> Bool {
        var accepted = false
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard AudioImportService.allowedExtensions.contains(ext) else {
                toast.show(String(format: String(localized: "transcribe.toast.unsupported"), ext))
                continue
            }
            let standard = url.standardizedFileURL
            guard !pendingFiles.contains(where: { $0.url.standardizedFileURL == standard }) else {
                continue
            }
            let file = PendingTranscribeFile(
                url: url, fileName: url.lastPathComponent, ext: ext,
                sizeBytes: AudioImportService.fileSizeBytes(url: url) ?? 0)
            pendingFiles.append(file)
            accepted = true
            // 时长探测异步回填（不改列序）
            Task { [weak self, fileID = file.id] in
                let ms = await AudioImportService.probeDurationMs(url: url)
                guard let self, let ms,
                      let index = self.pendingFiles.firstIndex(where: { $0.id == fileID }) else { return }
                self.pendingFiles[index].durationMs = ms
            }
        }
        if accepted { phase = .picked }
        return accepted
    }

    func removeFile(_ id: UUID) {
        pendingFiles.removeAll { $0.id == id }
        if pendingFiles.isEmpty { phase = .empty }
    }

    // MARK: 模型选择（页面独立；主线程）

    func setMode(_ mode: AppSettings.ASRMode) {
        selection.mode = mode
    }

    func setAPIProvider(_ provider: AppSettings.ASRProvider) {
        selection.apiProvider = provider
        selection.mode = .api
    }

    func setLocalModel(_ repoID: String) {
        selection.localRepoID = repoID
        selection.mode = .local
    }

    /// API 供应商已配置（Key 非空）——菜单 dim 与开始门槛。
    func isProviderConfigured(_ provider: AppSettings.ASRProvider) -> Bool {
        let key = (try? secrets.get(SecretAccount.asrAccount(for: provider))) ?? ""
        return !key.isEmpty
    }

    func isLocalModelAvailable(_ repoID: String?) -> Bool {
        guard let repoID else { return false }
        return isLocalModelInstalled(repoID)
    }

    /// 当前选择可开始转写（模型侧就绪）。
    var selectionValid: Bool {
        switch selection.mode {
        case .api: return isProviderConfigured(selection.apiProvider)
        case .local: return isLocalModelAvailable(selection.localRepoID)
        }
    }

    /// LLM 已配置（AI 总结按钮门槛；未配置禁用）——按总结设置解析（跟随全局或钉选家）。
    var llmConfigured: Bool {
        Self.summaryLLMConfig(settings: settingsRef, secrets: secrets)?.apiKey.isEmpty == false
    }

    // MARK: 开始 / 取消 / 重置（主线程）

    var canStart: Bool {
        phase == .picked && !pendingFiles.isEmpty && selectionValid
    }

    func startTranscription() {
        guard canStart else { return }
        let files = pendingFiles
        let engine: ASREngine = selection.mode == .local
            ? localEngineFactory(selection.localRepoID ?? "") : apiEngine
        let config = buildConfig(
            mode: selection.mode, apiProvider: selection.apiProvider, localRepoID: selection.localRepoID)
        let mode = FileTranscript.Mode(rawValue: selection.mode.rawValue) ?? .api
        let modelID: String
        let modelName: String
        if selection.mode == .local {
            modelID = selection.localRepoID ?? ""
            modelName = LocalModelCatalog.model(id: modelID)?.name ?? modelID
        } else {
            modelID = selection.apiProvider.rawValue
            modelName = selection.apiProvider.displayName
        }

        phase = .running
        isBatchRunning = true
        hasUnseenFailure = false
        batchStartedAt = Date()
        batchElapsedSeconds = 0
        // 预估系数：本地 RTF 实测 <0.5 取 0.45、API 取 0.3（粗估只影响假进度节奏）
        let factor = selection.mode == .local ? 0.45 : 0.3
        queueItems = files.map { file in
            var item = TranscribeQueueItem(dbID: nil, fileName: file.fileName, ext: file.ext)
            item.estimateSeconds = max(8.0, Double(file.durationMs ?? 20_000) / 1000.0 * factor)
            return item
        }
        startTicker()

        // 队列条目 id 快照（TASK-173）：后台循环按快照定位条目，不再读实时
        // `queueItems[index]`——实时数组可被任何 UI 路径清空，下标取值会直接崩。
        let itemIDs = queueItems.map(\.id)
        let repository = self.repository
        let audioStore = self.audioStore
        queueTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await FileTranscribeBatchRunner.runBatch(
                self: self, files: files, itemIDs: itemIDs,
                engine: engine, config: config, mode: mode,
                modelID: modelID, modelName: modelName,
                repository: repository, audioStore: audioStore,
                segmentSeconds: self.segmentSeconds)
        }
    }

    /// 取消整个队列：进行中标 failed(cancelled)（音频保留可重试）、未开始跳过；
    /// 收尾后 phase 回 picked（文件列表保留，可重新开始）。
    func cancelAll() {
        queueTask?.cancel()
    }

    /// 「转写下一个」/「＋ 新建转写」：重置回拖放空态（hist 查看态同此出口）。
    /// 批次运行中拒绝重置（TASK-173）：清空 `queueItems` 会让后台批次失去条目锚点，
    /// 且用户会丢失进行中的队列视图；重置入口本身在 running 态也不可见（双保险）。
    func resetToEmpty() {
        guard !isBatchRunning else { return }
        viewingEntryID = nil
        viewingDetail = nil
        pendingFiles = []
        batchResults = []
        queueItems = []
        itemElapsedSeconds = [:]
        phase = .empty
    }

    // MARK: 侧栏徽标

    /// 转写运行中侧栏徽标文本（如「42%」）；静止时 nil（2026-10-24 用户裁决：无「新」徽标）。
    var sidebarBadgeText: String? {
        guard phase == .running || retryingEntryID != nil else { return nil }
        return "\(Int((overallProgress * 100).rounded()))%"
    }

    /// 失败未回看标记（2026-10-25 用户裁决）：批次/重试以非取消失败收尾且用户
    /// 不在转写页 → 置位；进转写页（RootView 页切换钩子）或发起新批次/重试即清。
    /// （主线程读写纪律同本类其余可变状态。）
    var hasUnseenFailure = false

    /// 侧栏失败徽标显隐：静止（无运行百分比）且有失败未回看 → 红色 ⚠ chip。
    var sidebarShowsFailure: Bool {
        hasUnseenFailure && sidebarBadgeText == nil
    }

    /// 进转写页即视为已回看（⚠ 清账）。
    func markFailuresSeen() {
        hasUnseenFailure = false
    }

    /// 总进度 0…1 = (已完成数 + 当前进度) / 总数（重试态 = 单条进度）。
    var overallProgress: Double {
        if retryingEntryID != nil { return retryProgress }
        guard !queueItems.isEmpty else { return 0 }
        let finished = queueItems.filter { $0.state == .succeeded || $0.state == .failed }.count
        let current = queueItems.first { $0.state == .running }?.progress ?? 0
        return min(1, (Double(finished) + current) / Double(queueItems.count))
    }

    /// 批次收尾（主线程）：停 ticker；取消 → phase 回 picked（文件保留）；
    /// 正常 → phase=done + 拉批次结果 + 完成 Toast（不在转写页时）。
    func finishBatch(wasCancelled: Bool) {
        // 批次收口 = 守卫解除的唯一入口（TASK-173）；先于 reload/phase 变更，
        // 避免收尾期间 UI 仍认为批次在跑。
        isBatchRunning = false
        queueTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        if let started = batchStartedAt {
            batchElapsedSeconds = Date().timeIntervalSince(started)
        }
        reloadHistory()
        if wasCancelled {
            phase = .picked
            return
        }
        phase = .done
        let repository = self.repository
        let ids = queueItems.compactMap(\.dbID)
        Task.detached(priority: .utility) { [weak self] in
            // 增量取本批行（TASK-158：此前 fetchAll 全表物化 text/summary 后内存
            // first(where:) 匹配——随历史条数线性恶化）
            let results = ids.compactMap { try? repository.fetch(id: $0) }
            await MainActor.run {
                guard let self else { return }
                self.batchResults = results
                if results.contains(where: { $0.status == .succeeded }),
                   self.isOnTranscribePage?() != true {
                    self.toast.show(String(localized: "transcribe.toast.batchDone"))
                }
                // 失败徽标：非取消失败且用户不在页（取消是用户自己的动作，不打扰）
                if results.contains(where: { $0.status == .failed && $0.errorKind != "cancelled" }),
                   self.isOnTranscribePage?() != true {
                    self.hasUnseenFailure = true
                }
            }
        }
    }

    // MARK: 分段真进度（段循环经 MainActor.run 回写；TASK-151 起替代墙钟假进度）

    /// 分段开始：登记总段数（分段前 sliceCount 为 nil）。
    @MainActor
    func beginSliceProgress(itemID: UUID?, isRetry: Bool, count: Int) {
        if let itemID, let i = queueItems.firstIndex(where: { $0.id == itemID }) {
            queueItems[i].sliceCount = count
            queueItems[i].sliceIndex = 0
        }
        if isRetry { retryProgress = 0 }
    }

    /// 段完成：真进度（已完成/总数，完成跳 1 在收口处）+ 实时 ETA。
    @MainActor
    func advanceSliceProgress(
        itemID: UUID?, isRetry: Bool, done: Int, count: Int, remainingSeconds: Double
    ) {
        let fraction = count > 0 ? Double(done) / Double(count) : 1
        if let itemID, let i = queueItems.firstIndex(where: { $0.id == itemID }) {
            queueItems[i].progress = min(0.99, fraction)
            queueItems[i].sliceIndex = done
            if let started = queueItems[i].startedAt {
                let elapsed = Date().timeIntervalSince(started)
                itemElapsedSeconds[itemID] = elapsed
                queueItems[i].estimateSeconds = elapsed + max(0, remainingSeconds)
            }
        }
        if isRetry { retryProgress = min(0.99, fraction) }
    }

    // MARK: 已用秒 ticker（1s 墙钟驱动；TASK-151 起 progress 由段循环直写；
    // TASK-158 由 250ms 收敛至 1s——展示为 Int 秒粒度，sleep ≥1s 保证截断值
    // 单调递增不跳变；只写旁路字典/批次耗时，queueItems 不随 tick 失效）

    func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick(now: Date())
            }
        }
    }

    func tick(now: Date) {
        if let started = batchStartedAt {
            batchElapsedSeconds = now.timeIntervalSince(started)
        }
        // 已用秒展示刷新（progress/ETA 由段循环真值直写，见 advanceSliceProgress）
        if let item = queueItems.first(where: { $0.state == .running }),
           let itemStart = item.startedAt {
            itemElapsedSeconds[item.id] = now.timeIntervalSince(itemStart)
        }
        if retryingEntryID != nil, let start = retryStartedAt {
            retryElapsedSeconds = now.timeIntervalSince(start)
        }
    }

    // MARK: 配置组装（主线程：settings/secrets 非线程安全，批次开始前快照）

    func buildConfig(
        mode: AppSettings.ASRMode, apiProvider: AppSettings.ASRProvider, localRepoID: String?
    ) -> ASRConfig {
        let settings = settingsRef
        switch mode {
        case .local:
            // 本地引擎不消费 API 字段；model 填显示名（沿 ASRConfig.live 入库约定）
            let repo = localRepoID ?? ""
            return ASRConfig(model: LocalModelCatalog.model(id: repo)?.name ?? repo)
        case .api:
            // 指定供应商版 live：页面选择快照（不写回全局，§76），字段组装与听写管线同源
            return ASRConfig.live(settings: settings, secrets: secrets, provider: apiProvider)
        }
    }

    // MARK: 调试直入（DEBUG；--transcribe-picked/running/done/hist 截图走查用）

    #if DEBUG
    /// 注入演示态（仅空态且无历史时生效一次；不落库——history/batchResults 为纯内存演示值）。
    func seedDemoState(_ name: String) {
        guard phase == .empty, history.isEmpty, queueItems.isEmpty, batchResults.isEmpty else { return }
        switch name {
        case "picked":
            pendingFiles = [
                PendingTranscribeFile(
                    url: URL(fileURLWithPath: "/tmp/demo/weekly-sync.m4a"),
                    fileName: "weekly-sync.m4a", ext: "m4a", sizeBytes: 24_800_000, durationMs: 516_000),
                PendingTranscribeFile(
                    url: URL(fileURLWithPath: "/tmp/demo/podcast-ep12.mp3"),
                    fileName: "podcast-ep12.mp3", ext: "mp3", sizeBytes: 41_200_000, durationMs: 1_740_000),
            ]
            phase = .picked
        case "running":
            batchStartedAt = Date()
            var first = TranscribeQueueItem(dbID: nil, fileName: "weekly-sync.m4a", ext: "m4a")
            first.state = .succeeded
            first.progress = 1
            var second = TranscribeQueueItem(dbID: nil, fileName: "podcast-ep12.mp3", ext: "mp3")
            second.state = .running
            second.startedAt = Date().addingTimeInterval(-12)
            second.estimateSeconds = 40
            second.progress = 0.3
            var third = TranscribeQueueItem(dbID: nil, fileName: "voice-memo-0312.wav", ext: "wav")
            third.state = .waiting
            queueItems = [first, second, third]
            itemElapsedSeconds = [second.id: 12]
            batchElapsedSeconds = 12
            phase = .running
            startTicker()
        case "done":
            batchElapsedSeconds = 96
            batchResults = [
                FileTranscript(
                    createdAt: Date().timeIntervalSince1970 - 96,
                    fileName: "weekly-sync.m4a", fileExt: "m4a", fileSizeBytes: 24_800_000, durationMs: 516_000,
                    mode: .local, modelID: "demo/repo", modelName: "Qwen3-ASR 0.6B 4bit",
                    status: .succeeded,
                    text: "这一段是演示转写文本。项目周会首先同步了上周的交付进度：文件转写功能已进入视觉走查阶段，双栏布局与队列进度表现符合原型方案 D 的预期。接下来讨论了多文件串行转写的资源策略，决定沿用单 worker 会话共享方案，避免显存重复占用。最后确认了发布前的收尾清单，包括文案本地化完整性测试与构建签名验证。",
                    transcribeMs: 78_000),
                FileTranscript(
                    createdAt: Date().timeIntervalSince1970 - 40,
                    fileName: "meeting-alibaba.m4a", fileExt: "m4a", fileSizeBytes: 15_600_000, durationMs: 402_000,
                    mode: .api, modelID: "groq", modelName: "Groq API",
                    status: .failed,
                    errorKind: "timeout", errorMessage: "网络超时", transcribeMs: nil),
            ]
            phase = .done
        case "hist":
            let demos: [FileTranscript] = [
                FileTranscript(
                    id: 101, createdAt: Date().timeIntervalSince1970 - 3_600,
                    fileName: "weekly-sync.m4a", fileExt: "m4a", fileSizeBytes: 24_800_000, durationMs: 516_000,
                    mode: .local, modelID: "demo/repo", modelName: "Qwen3-ASR 0.6B 4bit",
                    status: .succeeded,
                    text: "这是历史条目的演示转写文本。周会记录：上周完成听写引擎的两级页改版，本周进入文件转写功能开发。设计走查通过后合并主线，发布前需补齐统计口径与文档。",
                    summary: "**会议主旨**：转写功能进入收尾——视觉走查通过，多文件策略定档。\n\n### 议题与决议\n- **进展**：听写引擎两级页改版完成；文件转写进入开发周。\n- **多文件策略**：沿用单 worker 会话共享，避免显存重复占用。\n\n### 行动项清单\n\n| 事项 | 完成时间 | 交付标准 |\n| --- | --- | --- |\n| 统计口径补齐 | 发布前 | 覆盖转写与总结两链路 |\n| 文档更新 | 发布前 | 与主线行为一致 |",
                    transcribeMs: 78_000),
                FileTranscript(
                    id: 102, createdAt: Date().timeIntervalSince1970 - 86_400,
                    fileName: "lecture-embedded.mp4", fileExt: "m4a", fileSizeBytes: 88_000_000,
                    mode: .api, modelID: "qwen", modelName: "QwenAI API",
                    status: .succeeded,
                    text: "嵌入式系统课程第十二讲：实时操作系统的时间确定性——调度延迟的三个来源与抖动测量方法。",
                    transcribeMs: 12_000),
                FileTranscript(
                    id: 103, createdAt: Date().timeIntervalSince1970 - 172_800,
                    fileName: "meeting-alibaba.m4a", fileExt: "m4a", fileSizeBytes: 15_600_000,
                    mode: .api, modelID: "groq", modelName: "Groq API",
                    status: .failed, errorKind: "timeout", errorMessage: "网络超时"),
            ]
            history = demos.map { item in
                FileTranscriptListItem(
                    id: item.id ?? 0, createdAt: item.createdAt, fileName: item.fileName,
                    modelName: item.modelName, status: item.status, errorKind: item.errorKind)
            }
            historyTotalCount = demos.count
            historyHasMore = false
            viewingDetail = demos[0]
            viewingEntryID = 101
        case "retrying":
            // hist 查看态 + 历史重试进行中（取消按钮截图/走查用）
            seedDemoState("hist")
            retryingEntryID = 101
            retryProgress = 0.35
            retryElapsedSeconds = 12
            retryStartedAt = Date()
            startTicker()
        default:
            break
        }
    }
    #endif
}
