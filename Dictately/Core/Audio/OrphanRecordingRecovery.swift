import Foundation

/// 孤儿录音恢复（PRD §7 Reliability / roadmap TASK-036）：
/// 进程崩溃/被杀后 `Recordings/` 里可能残留未入库的 WAV——启动时扫描，
/// 经用户确认后逐条走 ASR（**不粘贴**——恢复场景无目标光标）入库。
enum OrphanRecordingRecovery {
    /// 扫描存储目录中无 DB 引用的 WAV 文件名（按文件名时间戳升序恢复）。
    /// - Parameter olderThan: 宽限期（秒，默认 0 不设限）——只考虑修改时间早于
    ///   `now - olderThan` 的文件，防「启动扫描与刚开录的进行中录音」竞态把
    ///   在写文件误判孤儿（AppDelegate 启动扫描传 60s）。
    static func findOrphans(
        in store: AudioFileStore, entries: EntryRepository, olderThan grace: TimeInterval = 0
    ) throws -> [String] {
        let referenced = Set(try entries.fetchAll().compactMap(\.audioPath))
        let cutoff = Date().addingTimeInterval(-grace)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .filter { url in
                // 修改时间不可读时保守视为过期（可恢复的善后路径，宁多勿漏）
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return mtime < cutoff
            }
            .filter { !referenced.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.lastPathComponent)
    }

    /// 逐条转写入库（不粘贴、不弹面板——恢复是后台善后）。
    /// 每条独立失败处理：失败入库 failed，不影响后续条目。
    static func recover(
        paths: [String],
        store: AudioFileStore,
        entries: EntryRepository,
        asrEngine: ASREngine,
        config: ASRConfig,
        now: @escaping () -> Date = { Date() }
    ) async {
        for path in paths {
            guard let url = store.resolve(path: path) else { continue }
            // 音频时长估算（文件字节数 → ms；入库字段用，非精确计量）
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let durationMs = bytes * 1000 / 32_000 // 32KB/s（16kHz/16bit/mono）
            do {
                let transcript = try await asrEngine.transcribe(audioFileAt: url, config: config)
                _ = try entries.insert(Entry(
                    createdAt: now().timeIntervalSince1970,
                    type: .dictation,
                    status: .success,
                    audioPath: path,
                    audioDurationMs: durationMs,
                    rawText: transcript.text,
                    finalText: transcript.text,
                    asrModel: config.model,
                    asrLatencyMs: transcript.latencyMs,
                    pasted: false)) // 恢复不粘贴
                AppLog.pipeline.notice("orphan recovered: \(path, privacy: .public)")
            } catch let error as ASRError {
                _ = try? entries.insert(Entry(
                    createdAt: now().timeIntervalSince1970,
                    status: .failed,
                    errorKind: error.kindKey,
                    errorMessage: error.userMessage,
                    audioPath: path,
                    audioDurationMs: durationMs,
                    asrModel: config.model,
                    pasted: false))
                AppLog.pipeline.notice("orphan recovery failed: \(path, privacy: .public) kind=\(error.kindKey, privacy: .public)")
            } catch {
                AppLog.pipeline.error("orphan recovery unexpected error: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
