import Foundation
import Observation

// MARK: - 值类型（页面选择 / 待转文件 / 运行队列条目）

/// 总结 Prompt 预设的展示层解析（TASK-155；置于本文件 = 本地化键守卫扫描范围，
/// §68 纪律）。两套内置文案逐字取自用户 2026-10-25 提供货，键值勿修正。
extension AppSettings.SummaryPreset {
    /// 显示名（分段控件 / 摘要卡来源注）。
    var displayName: String {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.preset.meeting")
        case .expert: return String(localized: "transcribe.summary.preset.expert")
        case .custom: return String(localized: "transcribe.summary.preset.custom")
        }
    }

    /// 内置文案（custom 无内置 → nil）。
    var builtinPrompt: String? {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.prompt.meeting")
        case .expert: return String(localized: "transcribe.summary.prompt.expert")
        case .custom: return nil
        }
    }

    /// 职能副行（分段控件下方 desc；编辑器 fork 提示另见视图层）。
    var roleDescription: String {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.preset.meeting.desc")
        case .expert: return String(localized: "transcribe.summary.preset.expert.desc")
        case .custom: return String(localized: "transcribe.summary.preset.custom.desc")
        }
    }
}

/// 文件转写页面级模型选择（方案 D「转写模型」节）：页面独立，**不写回全局设置**——
/// 默认值取全局当前生效（asrMode + 当前供应商/本地模型），切换仅影响本页转写。
struct TranscribeModelSelection: Equatable {
    var mode: AppSettings.ASRMode
    /// mode == .api 时生效的供应商。
    var apiProvider: AppSettings.ASRProvider
    /// mode == .local 时生效的本地模型 repo id（nil = 本地无可选）。
    var localRepoID: String?

    /// 全局当前生效的快照（页面默认值）。
    static func current(settings: AppSettings) -> TranscribeModelSelection {
        TranscribeModelSelection(
            mode: settings.asrMode,
            apiProvider: settings.asrProvider,
            localRepoID: settings.activeLocalModel)
    }
}

/// 待转文件（picked 态工作台列表项；开始转写后随批次快照进队列）。
struct PendingTranscribeFile: Identifiable {
    let id = UUID()
    /// 原文件 URL（导入前展示用；转写时经 audioStore.copyImport 拷贝入库）。
    let url: URL
    let fileName: String
    let ext: String
    let sizeBytes: Int64
    /// 异步探测回填（探测中 nil → UI 显示「—」）。
    var durationMs: Int?
}

/// 运行队列条目（running 态左栏队列；与 DB 行一一对应，dbID 在插行后回填）。
struct TranscribeQueueItem: Identifiable {
    enum State: Equatable {
        case waiting, running, succeeded, failed
    }

    let id = UUID()
    /// 对应 file_transcripts 行（插入后回填）。
    var dbID: Int64?
    let fileName: String
    let ext: String
    var state: State = .waiting
    /// 分段真进度 0…1（TASK-151：已完成段/总段数，段循环直写；完成跳 1）。
    var progress: Double = 0
    /// 当前段序号/总段数（running 态「分段 x/N」标签；分段前 nil）。
    var sliceIndex: Int?
    var sliceCount: Int?
    /// 转写耗时预估（秒；分段循环用已测单片均值×剩余段实时更新）。
    /// 本条已用秒在控制器 `itemElapsedSeconds`（旁路字典——ticker 每 1s 写它，
    /// queueItems 只在真进度/状态变化时失效，视图依赖粒度下沉配套，TASK-158）。
    var estimateSeconds: Double = 10
    var startedAt: Date?
    var errorMessage: String?
    /// 失败分类（ASRError.kindKey / cancelled / importFailed）。
    var errorKind: String?
}

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

    private let settingsRef: AppSettings
    private let secrets: SecretStore
    private let repository: FileTranscriptRepository
    private let audioStore: AudioFileStore
    private let apiEngine: ASREngine
    private let localEngineFactory: (String) -> ASREngine
    private let llmEngine: LLMEngine
    private let toast: ToastPresenter
    /// 本地模型已下载判定（菜单 dim 与开始门槛）。
    private let isLocalModelInstalled: (String) -> Bool
    /// 分段目标段长（秒；TASK-151 统一切片管线。参数化供测试注入）。
    private let segmentSeconds: Double

    // MARK: 页面状态（方案 D 状态机：empty/picked/running/done + hist = viewingEntryID 非 nil）

    enum Phase: Equatable {
        case empty, picked, running, done
    }

    private(set) var phase: Phase = .empty
    private(set) var pendingFiles: [PendingTranscribeFile] = []
    private(set) var selection: TranscribeModelSelection
    /// 运行队列（running 态渲染源；顺序 = 开始时的文件顺序）。
    private(set) var queueItems: [TranscribeQueueItem] = []
    /// done 态批次结果（按队列顺序的落库行快照）。
    private(set) var batchResults: [FileTranscript] = []
    /// hist 态：右栏点入的历史条目 id（nil = 非查看态）。
    var viewingEntryID: Int64?
    /// hist 态左栏详情（全行，含 text/summary——列表源只存轻量列，TASK-158；
    /// selectHistoryEntry 后台拉取，回填前 nil = 加载占位）。总结/重试完成时刷新。
    private(set) var viewingDetail: FileTranscript?
    /// 历史重试进行中的条目 id（hist 态左栏显示进度卡，原型 h._run）。
    private(set) var retryingEntryID: Int64?
    private(set) var retryProgress: Double = 0
    private(set) var retryElapsedSeconds: Double = 0
    private var retryStartedAt: Date?

    /// 历史列表（右栏渲染源；倒序；轻量行——大列详情走 viewingDetail，TASK-158）。
    private(set) var history: [FileTranscriptListItem] = []

    /// AI 总结进行中的条目 id 集合（按钮三态：未总结/正在总结…/已总结=summary 非空）。
    private(set) var summarizingIDs: Set<Int64> = []

    /// 批次起止（done 头「用时」）。
    private var batchStartedAt: Date?
    private(set) var batchElapsedSeconds: Double = 0

    /// 各队列条目已用秒（旁路字典：ticker 每 1s 只写它，queueItems 不随之失效——
    /// ETA 文本叶子视图单独读取，整页/侧栏徽标不再每秒重算，TASK-158）。
    private(set) var itemElapsedSeconds: [UUID: Double] = [:]

    private var queueTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var historyReloadGeneration = 0
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

        let repository = self.repository
        let audioStore = self.audioStore
        queueTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await Self.runBatch(
                self: self, files: files, engine: engine, config: config, mode: mode,
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
    func resetToEmpty() {
        viewingEntryID = nil
        viewingDetail = nil
        pendingFiles = []
        batchResults = []
        queueItems = []
        itemElapsedSeconds = [:]
        phase = .empty
    }

    // MARK: 历史（主线程入口；IO 后台）

    func selectHistoryEntry(_ id: Int64?) {
        viewingEntryID = id
        viewingDetail = nil
        guard let id else { return }
        let repository = self.repository
        Task.detached(priority: .utility) { [weak self] in
            let entry = try? repository.fetch(id: id)
            await MainActor.run {
                guard let self, self.viewingEntryID == id else { return }
                self.viewingDetail = entry
            }
        }
    }

    /// 历史列表刷新（轻量列 + 300ms 合并窗口——批次每文件开始/完成/失败/总结各一拉，
    /// 全表拉取随历史条数线性恶化；世代守卫防旧查询迟到覆盖，沿 HistoryView 惯例）。
    func reloadHistory() {
        historyReloadGeneration += 1
        let generation = historyReloadGeneration
        historyReloadTask?.cancel()
        let repository = self.repository
        historyReloadTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let entries = (try? repository.fetchListItems()) ?? []
            await MainActor.run {
                guard let self, self.historyReloadGeneration == generation else { return }
                self.history = entries
            }
        }
    }

    /// 删除历史条目（行 + store 内音频同删）。
    func deleteEntry(_ id: Int64) {
        let repository = self.repository
        let audioStore = self.audioStore
        Task.detached(priority: .utility) { [weak self] in
            let audioPath = (try? repository.delete(id: id)) ?? nil
            if let audioPath {
                audioStore.delete(path: audioPath)
            }
            await MainActor.run {
                guard let self else { return }
                if self.viewingEntryID == id {
                    self.viewingEntryID = nil
                    self.viewingDetail = nil
                }
                self.reloadHistory()
                self.toast.show(String(localized: "transcribe.toast.deleted"))
            }
        }
    }

    /// 历史失败条目「重新转写」（单文件迷你批次；页面留 hist 态，左栏显示进度卡）。
    func retryEntry(_ id: Int64) {
        guard retryingEntryID == nil else { return }
        // 全行取库（列表源为轻量行无 audioPath，TASK-158）
        guard let entry = try? repository.fetch(id: id),
              let stored = entry.audioPath,
              let entryID = entry.id else { return }
        let mode: AppSettings.ASRMode = entry.mode == .local ? .local : .api
        let apiProvider = AppSettings.ASRProvider(rawValue: entry.modelID) ?? .qwen
        let localRepoID = entry.mode == .local ? entry.modelID : nil
        let engine: ASREngine = entry.mode == .local ? localEngineFactory(entry.modelID) : apiEngine
        let config = buildConfig(mode: mode, apiProvider: apiProvider, localRepoID: localRepoID)
        let fileName = entry.fileName

        retryingEntryID = entryID
        hasUnseenFailure = false // 用户正发起重试 = 在关注结果，旧 ⚠ 清账
        retryProgress = 0
        retryElapsedSeconds = 0
        retryStartedAt = Date()
        startTicker()

        let repository = self.repository
        let audioStore = self.audioStore
        let segmentSeconds = self.segmentSeconds
        retryTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let storedURL = audioStore.resolve(path: stored)
            if let storedURL {
                await Self.runSegmented(
                    self: self, entryID: entryID, source: storedURL, engine: engine,
                    config: config, repository: repository, itemID: nil, isRetry: true,
                    segmentSeconds: segmentSeconds)
            } else {
                await Self.failEntry(
                    self: self, repository: repository, id: entryID,
                    kind: "importFailed", message: String(localized: "transcribe.error.decode"),
                    itemID: nil)
            }
            await MainActor.run {
                self.retryingEntryID = nil
                self.reloadHistory()
                if let updated = self.syncUpdatedRow(entryID) {
                    if updated.status == .succeeded, self.isOnTranscribePage?() != true {
                        self.toast.show(String(format: String(localized: "transcribe.toast.done"), fileName))
                    }
                    if updated.status == .failed, updated.errorKind != "cancelled",
                       self.isOnTranscribePage?() != true {
                        self.hasUnseenFailure = true
                    }
                }
            }
        }
    }

    /// 取消历史重试：进行中标 failed(cancelled)（音频保留可重试）；
    /// 收尾（retryingEntryID 清空 + 历史刷新）由 retryTask 自身完成。
    func cancelRetry() {
        retryTask?.cancel()
    }

    /// 行更新后的查看态同步（§85 收敛）：重取库行，若用户正查看该条则刷新详情；
    /// 返回行供调用方做后续判定（Toast/徽标/批次列表同步），取不到返回 nil。
    @discardableResult
    private func syncUpdatedRow(_ id: Int64) -> FileTranscript? {
        guard let updated = try? repository.fetch(id: id) else { return nil }
        if viewingEntryID == id {
            viewingDetail = updated
        }
        return updated
    }

    /// AI 总结（LLM 引擎 + §29 system+user 双消息契约）：服务与模型按总结设置解析
    /// （TASK-155：跟随全局或钉选家 + 模型快照），system = 生效预设文案（custom 预设
    /// 取 trim 后自定义）；结果 Markdown 原文落库。isRegeneration = 摘要卡「重新生成」
    /// （TASK-157）：同一链路覆盖重写既有摘要，成功后弹 Toast；首次总结不弹。
    func summarize(_ id: Int64, isRegeneration: Bool = false) {
        guard !summarizingIDs.contains(id),
              let entry = (try? repository.fetch(id: id)),
              let text = entry.text, !text.isEmpty else { return }
        guard let config = Self.summaryLLMConfig(settings: settingsRef, secrets: secrets),
              !config.apiKey.isEmpty else {
            toast.show(String(localized: "transcribe.summary.llmMissing"), info: true)
            return
        }
        let system = Self.resolvedSummaryPrompt(
            preset: settingsRef.transcribeSummaryPreset,
            custom: settingsRef.transcribeSummaryPrompt)
        let repository = self.repository
        summarizingIDs.insert(id)
        Task.detached(priority: .userInitiated) { [weak self, llmEngine] in
            do {
                let result = try await llmEngine.complete(system: system, user: text, config: config)
                try repository.updateSummary(id: id, summary: result.text)
                await MainActor.run {
                    guard let self else { return }
                    self.summarizingIDs.remove(id)
                    self.reloadHistory()
                    if let updated = self.syncUpdatedRow(id) {
                        if let index = self.batchResults.firstIndex(where: { $0.id == id }) {
                            self.batchResults[index] = updated
                        }
                    }
                    if isRegeneration {
                        self.toast.show(String(localized: "transcribe.summary.regen.done"))
                    }
                }
            } catch {
                AppLog.pipeline.error("file transcript summarize failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    guard let self else { return }
                    self.summarizingIDs.remove(id)
                    let message = (error as? LLMError)?.userMessage ?? String(localized: "transcribe.summary.failed")
                    self.toast.show(message, info: true)
                }
            }
        }
    }

    // MARK: - 总结设置解析（TASK-155；纯函数，聚合层纪律同 §56）

    /// 总结生效 LLM 解析结果：生效供应商 / 是否跟随全局 / 生效模型。
    struct SummaryLLMResolution: Equatable {
        let provider: AppSettings.LLMProvider
        let isFollow: Bool
        let model: String
    }

    /// 总结 Prompt 生效文案：custom 预设取 trim 后自定义（防御：空回落会议默认——
    /// 保存闸已挡空值，此为 defaults 直写绕过 UI 的兜底）；内置预设逐字内置文案
    /// （不读 transcribeSummaryPrompt）。
    static func resolvedSummaryPrompt(
        preset: AppSettings.SummaryPreset, custom: String
    ) -> String {
        guard preset == .custom else { return preset.builtinPrompt ?? "" }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AppSettings.SummaryPreset.meeting.builtinPrompt ?? "" }
        return trimmed
    }

    /// 总结 LLM 解析（纯函数）：跟随全局（默认）读「AI 服务」页当前供应商与其生效
    /// 模型；钉选家模型 = 自定义 ID 优先，否则快照 ID（空则该家当前生效模型——
    /// 钉选为快照语义，钉选瞬间的值落库，此后不随「AI 服务」页改模型联动）。
    static func resolvedSummaryLLM(settings: AppSettings) -> SummaryLLMResolution {
        if let pinned = settings.transcribeSummaryPinnedProvider {
            let model: String
            if settings.transcribeSummaryUsesCustomModel {
                model = settings.transcribeSummaryCustomModelID
            } else {
                let snapshot = settings.transcribeSummaryModel
                model = snapshot.isEmpty ? settings.llmModel(for: pinned) : snapshot
            }
            return SummaryLLMResolution(provider: pinned, isFollow: false, model: model)
        }
        let global = settings.llmProvider
        return SummaryLLMResolution(
            provider: global, isFollow: true, model: settings.llmModel(for: global))
    }

    /// 总结请求配置：跟随全局 → live；钉选 → 按指定家组装（模型覆写；baseURL 无效
    /// 返回 nil → 调用方走未配置拦截）。
    static func summaryLLMConfig(settings: AppSettings, secrets: SecretStore) -> LLMConfig? {
        let resolution = resolvedSummaryLLM(settings: settings)
        guard !resolution.isFollow else {
            return LLMConfig.live(settings: settings, secrets: secrets)
        }
        return LLMConfig.resolved(
            provider: resolution.provider,
            model: resolution.model,
            settings: settings,
            secrets: secrets)
    }

    /// 自定义 Prompt 态（摘要卡「已自定义」chip）：预设 = custom。
    var summaryUsesCustomPrompt: Bool {
        settingsRef.transcribeSummaryPreset == .custom
    }

    /// 总结设置非默认态（页头「总结设置」蓝点）：预设 ≠ 会议纪要助理，或已钉选服务。
    var summarySettingsCustomized: Bool {
        settingsRef.transcribeSummaryPreset != .meeting
            || settingsRef.transcribeSummaryPinnedProvider != nil
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
    private(set) var hasUnseenFailure = false

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

    // MARK: - 批次执行（后台；静态方法 + 依赖显式传参，状态回写经 MainActor.run）

    /// 串行逐文件：拷贝入库 → 插 running 行 → 分段转写（统一切片管线）→ 原地
    /// 更新行。单文件失败不炸批次；取消即停止后续（收尾 phase 回 picked）。
    private static func runBatch(
        self weakSelf: FileTranscribeController?,
        files: [PendingTranscribeFile], engine: ASREngine, config: ASRConfig,
        mode: FileTranscript.Mode, modelID: String, modelName: String,
        repository: FileTranscriptRepository, audioStore: AudioFileStore,
        segmentSeconds: Double
    ) async {
        var cancelled = false
        for (index, file) in files.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let itemID = await MainActor.run { weakSelf?.queueItems[index].id }

            // 拷贝入库（失败 = 无行可落，仅队列标记）
            guard let stored = try? audioStore.copyImport(intoStore: file.url) else {
                await markItem(weakSelf, itemID, .failed, "importFailed",
                               String(localized: "transcribe.error.copy"))
                continue
            }
            let entry = FileTranscript(
                createdAt: Date().timeIntervalSince1970,
                fileName: file.fileName, fileExt: file.ext, fileSizeBytes: file.sizeBytes,
                durationMs: file.durationMs, audioPath: stored.lastPathComponent,
                mode: mode, modelID: modelID, modelName: modelName, status: .running)
            guard let inserted = try? repository.insert(entry), let entryID = inserted.id else {
                await markItem(weakSelf, itemID, .failed, "importFailed",
                               String(localized: "transcribe.error.copy"))
                continue
            }
            await MainActor.run {
                guard let weakSelf else { return }
                if let i = weakSelf.queueItems.firstIndex(where: { $0.id == itemID }) {
                    weakSelf.queueItems[i].dbID = entryID
                    weakSelf.queueItems[i].state = .running
                    weakSelf.queueItems[i].startedAt = Date()
                }
                weakSelf.reloadHistory()
            }

            // 分段转写（TASK-151 统一切片管线：本地/API 同路径，段临时目录自清）
            await Self.runSegmented(
                self: weakSelf, entryID: entryID, source: stored, engine: engine,
                config: config, repository: repository, itemID: itemID, isRetry: false,
                segmentSeconds: segmentSeconds)

            if Task.isCancelled { cancelled = true; break }
        }
        let wasCancelled = cancelled
        await MainActor.run { weakSelf?.finishBatch(wasCancelled: wasCancelled) }
    }

    /// 单文件分段转写 + 失败收口（TASK-151 统一切片管线）：
    /// 预处理分段（统一 16k WAV，本地/API 同路径）→ 逐段转写（网络错误单片自动
    /// 重试一次；单段塌缩降档对半重切）→ 拼接落库。真进度 = 已完成段/总段数；
    /// 取消在段边界生效；段临时目录收口即清。
    private static func runSegmented(
        self weakSelf: FileTranscribeController?,
        entryID: Int64, source: URL, engine: ASREngine, config: ASRConfig,
        repository: FileTranscriptRepository, itemID: UUID?, isRetry: Bool,
        segmentSeconds: Double
    ) async {
        let segDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictately-segments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: segDir) }

        // 1. 预处理分段（解码失败 = importFailed，沿 TASK-150 语义）
        let segments: [URL]
        do {
            let src = source, dir = segDir, seconds = segmentSeconds
            segments = try await Task.detached(priority: .userInitiated) {
                try AudioImportService.prepareSegments(source: src, directory: dir, segmentSeconds: seconds)
            }.value
        } catch {
            await failEntry(
                self: weakSelf, repository: repository, id: entryID,
                kind: "importFailed", message: String(localized: "transcribe.error.decode"),
                itemID: itemID)
            return
        }
        guard !segments.isEmpty else {
            await failEntry(
                self: weakSelf, repository: repository, id: entryID,
                kind: "importFailed", message: String(localized: "transcribe.error.decode"),
                itemID: itemID)
            return
        }

        await MainActor.run {
            weakSelf?.beginSliceProgress(itemID: itemID, isRetry: isRetry, count: segments.count)
        }

        // 2. 逐段转写（段序即拼接序）
        let startedAt = Date()
        var texts: [String] = []
        var droppedHalfSegments = 0
        var sliceWalls: [Double] = []

        for (index, segment) in segments.enumerated() {
            if Task.isCancelled {
                await failEntry(
                    self: weakSelf, repository: repository, id: entryID,
                    kind: "cancelled", message: String(localized: "transcribe.error.cancelled"),
                    itemID: itemID)
                return
            }
            do {
                let sliceStart = Date()
                let (text, dropped) = try await transcribeSegmentWithGuard(
                    segment: segment, engine: engine, config: config,
                    segmentSeconds: segmentSeconds, segRoot: segDir)
                droppedHalfSegments += dropped
                texts.append(text)
                sliceWalls.append(Date().timeIntervalSince(sliceStart))
            } catch is CancellationError {
                await failEntry(
                    self: weakSelf, repository: repository, id: entryID,
                    kind: "cancelled", message: String(localized: "transcribe.error.cancelled"),
                    itemID: itemID)
                return
            } catch let error as ASRError {
                // 单段无语音（纯音乐/静音段）= 空贡献不炸整文件；全部段皆空时收口 emptyResult
                if case .emptyResult = error {
                    texts.append("")
                } else {
                    await failEntry(
                        self: weakSelf, repository: repository, id: entryID,
                        kind: error.kindKey, message: error.userMessage, itemID: itemID)
                    return
                }
            } catch {
                await failEntry(
                    self: weakSelf, repository: repository, id: entryID,
                    kind: "badResponse", message: error.localizedDescription, itemID: itemID)
                return
            }

            // 真进度 + 实时 ETA（已测单片均值 × 剩余段）
            let done = index + 1
            let average = sliceWalls.reduce(0, +) / Double(sliceWalls.count)
            let remaining = Double(segments.count - done) * average
            await MainActor.run {
                weakSelf?.advanceSliceProgress(
                    itemID: itemID, isRetry: isRetry, done: done,
                    count: segments.count, remainingSeconds: remaining)
            }
        }

        // 3. 收口：拼接（丢弃段以尾注披露）+ 落库
        var joined = texts.joined(separator: "\n")
        if droppedHalfSegments > 0 {
            joined += "\n\n" + String(
                format: String(localized: "transcribe.result.droppedSegments"), droppedHalfSegments)
        }
        let wallMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await failEntry(
                self: weakSelf, repository: repository, id: entryID,
                kind: ASRError.emptyResult.kindKey, message: ASRError.emptyResult.userMessage,
                itemID: itemID)
            return
        }
        guard var row = try? repository.fetch(id: entryID) else {
            await markItem(weakSelf, itemID, .failed, "importFailed", "row missing")
            return
        }
        row.status = .succeeded
        row.text = joined
        row.transcribeMs = wallMs
        row.completedAt = Date().timeIntervalSince1970
        row.errorKind = nil
        row.errorMessage = nil
        _ = try? repository.update(row)
        await MainActor.run {
            guard let weakSelf else { return }
            if let itemID, let i = weakSelf.queueItems.firstIndex(where: { $0.id == itemID }) {
                weakSelf.queueItems[i].state = .succeeded
                weakSelf.queueItems[i].progress = 1
            }
            if isRetry { weakSelf.retryProgress = 1 }
            weakSelf.reloadHistory()
        }
    }

    /// 单段转写 + 塌缩护栏：结果塌缩 → 对半重切逐半转写；半段仍塌缩 → 丢弃该半
    /// （返回丢弃计数，成品尾部以尾注披露——不静默丢、也不交付垃圾）。半段其余
    /// 错误原样上抛（整文件收口）；半段无语音 = 空贡献。重切自身失败 → 整段丢弃。
    private static func transcribeSegmentWithGuard(
        segment: URL, engine: ASREngine, config: ASRConfig,
        segmentSeconds: Double, segRoot: URL
    ) async throws -> (text: String, dropped: Int) {
        let transcript = try await transcribeWithAutoRetry(engine, audioFileAt: segment, config: config)
        guard TranscriptCollapseDetector.isCollapsed(transcript.text) else {
            return (transcript.text, 0)
        }
        AppLog.pipeline.notice("file transcribe slice collapsed, re-slicing at half granularity")

        let halfDir = segRoot.appendingPathComponent("halves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: halfDir) }
        let halves: [URL]
        do {
            let src = segment, dir = halfDir, seconds = segmentSeconds / 2
            halves = try await Task.detached(priority: .userInitiated) {
                try AudioImportService.prepareSegments(source: src, directory: dir, segmentSeconds: seconds)
            }.value
        } catch {
            return ("", 1)
        }

        var halfTexts: [String] = []
        var dropped = 0
        for half in halves {
            if Task.isCancelled { throw CancellationError() }
            do {
                let result = try await transcribeWithAutoRetry(engine, audioFileAt: half, config: config)
                if TranscriptCollapseDetector.isCollapsed(result.text) {
                    dropped += 1
                } else {
                    halfTexts.append(result.text)
                }
            } catch let error as ASRError where error == .emptyResult {
                continue // 半段无语音 = 空贡献
            }
        }
        return (halfTexts.joined(separator: "\n"), dropped)
    }

    /// 失败统一收口：更新 DB 行 + 队列标记（不阻断后续文件）。
    private static func failEntry(
        self weakSelf: FileTranscribeController?,
        repository: FileTranscriptRepository, id: Int64,
        kind: String, message: String, itemID: UUID?
    ) async {
        if var row = try? repository.fetch(id: id) {
            row.status = .failed
            row.errorKind = kind
            row.errorMessage = message
            row.completedAt = Date().timeIntervalSince1970
            _ = try? repository.update(row)
        }
        await markItem(weakSelf, itemID, .failed, kind, message)
        await MainActor.run { weakSelf?.reloadHistory() }
    }

    /// 队列条目标记（后台 → 主线程）。
    private static func markItem(
        _ weakSelf: FileTranscribeController?, _ itemID: UUID?,
        _ state: TranscribeQueueItem.State, _ kind: String?, _ message: String?
    ) async {
        guard let itemID else { return }
        await MainActor.run {
            guard let weakSelf,
                  let i = weakSelf.queueItems.firstIndex(where: { $0.id == itemID }) else { return }
            weakSelf.queueItems[i].state = state
            weakSelf.queueItems[i].errorKind = kind
            weakSelf.queueItems[i].errorMessage = message
        }
    }

    /// 批次收尾（主线程）：停 ticker；取消 → phase 回 picked（文件保留）；
    /// 正常 → phase=done + 拉批次结果 + 完成 Toast（不在转写页时）。
    private func finishBatch(wasCancelled: Bool) {
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
    private func beginSliceProgress(itemID: UUID?, isRetry: Bool, count: Int) {
        if let itemID, let i = queueItems.firstIndex(where: { $0.id == itemID }) {
            queueItems[i].sliceCount = count
            queueItems[i].sliceIndex = 0
        }
        if isRetry { retryProgress = 0 }
    }

    /// 段完成：真进度（已完成/总数，完成跳 1 在收口处）+ 实时 ETA。
    @MainActor
    private func advanceSliceProgress(
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

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick(now: Date())
            }
        }
    }

    private func tick(now: Date) {
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

    private func buildConfig(
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

    /// ASR 转写 + 网络类错误自动重试一次（沿 DictationPipeline 语义；取消态不重试）。
    private static func transcribeWithAutoRetry(
        _ engine: ASREngine, audioFileAt url: URL, config: ASRConfig
    ) async throws -> ASRTranscript {
        try await withAutoRetryOnce(
            retryOn: { (error: ASRError) in error.isNetworkError },
            betweenAttempts: { error in
                AppLog.pipeline.notice(
                    "file transcribe network error, auto-retry 1/1 (\(error.kindKey, privacy: .public))")
            }
        ) {
            try await engine.transcribe(audioFileAt: url, config: config)
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
