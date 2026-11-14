import Foundation

/// 文件转写批次执行器（TASK-187）：从控制器迁出的静态执行链（串行批次 →
/// 分段 → 单段塌缩护栏 → 失败/队列标记）。状态回写仍经 `FileTranscribeController`
/// 的 MainActor 入口，依赖全部显式传参，避免后台持有控制器引用做隐式 IO。
enum FileTranscribeBatchRunner {
// MARK: - 批次执行（后台；静态方法 + 依赖显式传参，状态回写经 MainActor.run；TASK-187 迁出）

/// 串行逐文件：拷贝入库 → 插 running 行 → 分段转写（统一切片管线）→ 原地
/// 更新行。单文件失败不炸批次；取消即停止后续（收尾 phase 回 picked）。
static func runBatch(
    self weakSelf: FileTranscribeController?,
    files: [PendingTranscribeFile], itemIDs: [UUID],
    engine: ASREngine, config: ASRConfig,
    mode: FileTranscript.Mode, modelID: String, modelName: String,
    repository: FileTranscriptRepository, audioStore: AudioFileStore,
    segmentSeconds: Double
) async {
    var cancelled = false
    for (index, file) in files.enumerated() {
        if Task.isCancelled { cancelled = true; break }
        // 条目 id 取启动时快照（TASK-173）：不再读实时 `queueItems[index]`——
        // 该数组可被 UI 路径清空，越界取值会崩；快照同时保证条目与文件一一对应。
        let itemID: UUID? = index < itemIDs.count ? itemIDs[index] : nil

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
static func runSegmented(
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
    // 保存失败必须收口为失败（TASK-174）：此前 `try?` 吞错误、UI 仍标 succeeded，
    // 历史行却停在 running（重启后被归一成「应用退出时中断」），用户以为成功过。
    do {
        try repository.update(row)
    } catch {
        AppLog.pipeline.error(
            "file transcript save failed: \(String(describing: error), privacy: .public)")
        await failEntry(
            self: weakSelf, repository: repository, id: entryID,
            kind: "saveFailed", message: String(localized: "transcribe.error.saveFailed"),
            itemID: itemID)
        return
    }
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
static func transcribeSegmentWithGuard(
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
static func failEntry(
    self weakSelf: FileTranscribeController?,
    repository: FileTranscriptRepository, id: Int64,
    kind: String, message: String, itemID: UUID?
) async {
    if var row = try? repository.fetch(id: id) {
        row.status = .failed
        row.errorKind = kind
        row.errorMessage = message
        row.completedAt = Date().timeIntervalSince1970
        do {
            try repository.update(row)
        } catch {
            AppLog.pipeline.error(
                "file transcript fail-state write failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    } else {
        AppLog.pipeline.error(
            "file transcript fail-state row missing id=\(id, privacy: .public)")
    }
    await markItem(weakSelf, itemID, .failed, kind, message)
    await MainActor.run { weakSelf?.reloadHistory() }
}

/// 队列条目标记（后台 → 主线程）。
static func markItem(
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


/// ASR 转写 + 网络类错误自动重试一次（沿 DictationPipeline 语义；取消态不重试）。
static func transcribeWithAutoRetry(
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
}
