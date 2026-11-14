import Foundation

/// 文件转写历史/重试/总结入口（TASK-187 文件拆分，行为零变化）。
extension FileTranscribeController {
// MARK: - 历史（主线程入口；IO 后台；TASK-187 从控制器迁出）

    /// 历史条目点选。批次运行中拒绝（TASK-173）：hist 视图会顶掉 running 队列、
    /// 且页头「＋ 新建转写」随之出现，形成「运行中清空队列」的可达路径。
    func selectHistoryEntry(_ id: Int64?) {
        guard !isBatchRunning else { return }
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
        historyLoadMoreTask?.cancel()
        isLoadingMoreHistory = false
        let repository = self.repository
        let pageSize = Self.historyPageSize
        historyReloadTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let entries = (try? repository.fetchListItems(limit: pageSize, offset: 0)) ?? []
            let total = (try? repository.fetchCount()) ?? entries.count
            await MainActor.run {
                guard let self, self.historyReloadGeneration == generation else { return }
                self.history = entries
                self.historyTotalCount = total
                self.historyHasMore = entries.count < total
            }
        }
    }

    /// 加载下一页（TASK-185）：追加去重；与整页刷新共用世代守卫，刷新到来即作废。
    func loadMoreHistory() {
        guard historyHasMore, !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        let generation = historyReloadGeneration
        let offset = history.count
        let pageSize = Self.historyPageSize
        let repository = self.repository
        historyLoadMoreTask?.cancel()
        historyLoadMoreTask = Task.detached(priority: .utility) { [weak self] in
            let page = (try? repository.fetchListItems(limit: pageSize, offset: offset)) ?? []
            let total = (try? repository.fetchCount()) ?? 0
            await MainActor.run {
                guard let self else { return }
                guard self.historyReloadGeneration == generation else {
                    self.isLoadingMoreHistory = false
                    return
                }
                let existing = Set(self.history.map(\.id))
                self.history.append(contentsOf: page.filter { !existing.contains($0.id) })
                self.historyTotalCount = total
                self.historyHasMore = self.history.count < total
                self.isLoadingMoreHistory = false
            }
        }
    }

    /// 删除历史条目（行 + store 内音频同删）。
    func deleteEntry(_ id: Int64) {
        let repository = self.repository
        let audioStore = self.audioStore
        Task.detached(priority: .utility) { [weak self] in
            let audioPath: String?
            do {
                audioPath = try repository.delete(id: id)
            } catch {
                // 删除失败要告诉用户（TASK-174）：此前 try? 静默，行与音频都可能还在。
                AppLog.pipeline.error(
                    "file transcript delete failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self?.toast.show(
                        String(localized: "transcribe.toast.deleteFailed"), info: true)
                }
                return
            }
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
        guard let entry = try? repository.fetch(id: id), let entryID = entry.id else { return }
        // 音频已过保留期清理（TASK-186）：重试入口给明确反馈，而不是静默失败。
        guard let stored = entry.audioPath else {
            toast.show(String(localized: "transcribe.error.audioCleaned"), info: true)
            return
        }
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
                await FileTranscribeBatchRunner.runSegmented(
                    self: self, entryID: entryID, source: storedURL, engine: engine,
                    config: config, repository: repository, itemID: nil, isRetry: true,
                    segmentSeconds: segmentSeconds)
            } else {
                await FileTranscribeBatchRunner.failEntry(
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

}
