import Foundation

/// 录音文件管理（FR-002/FR-018）：统一管理
/// `~/Library/Application Support/Dictately/Recordings/` 下的 WAV。
///
/// 职责：临时文件命名 `rec-{ISO8601}.wav`、移入正式目录、删除、按存储路径反解；
/// 以及为 10MB 编码后上限提供发送前预判 `isLikelyOverLimit(durationMs:)`。
///
/// 目录注入便于测试（临时目录），生产用 `defaultDirectory()`。
final class AudioFileStore {
    /// 编码后（Base64）字节上限：Qwen ASR 10MB（PRD §11 转写表）。
    /// 取 10 × 1024 × 1024 字节。
    static let encodedByteLimit = 10 * 1024 * 1024

    /// 原始 WAV 字节速率：16kHz × 16bit × 单声道 = 32000 B/s（PRD §2 录音格式）。
    static let wavBytesPerSecond = 32_000.0

    /// 录音根目录（注入；默认 `~/Library/Application Support/Dictately/Recordings/`）。
    let directory: URL

    /// 初始化即确保目录存在（含父目录，PRD Verify：目录自动创建）。
    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            self.directory = Self.defaultDirectory()
        }
        try FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    /// 生产目录（与 SQLite 同级：`~/Library/Application Support/Dictately/Recordings/`）。
    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dictately", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    // MARK: - 命名

    /// 生成下一个录音文件 URL：`rec-{ISO8601 时间戳}.wav`。
    ///
    /// 时间戳用 ISO 8601 基本格式 `20261001T123456.789Z`（避免冒号——Finder 会把
    /// 冒号显示成斜杠，复制路径时易混淆）；毫秒保证唯一性兜底，同毫秒冲突再加序号。
    func makeRecordingURL(date: Date = Date()) -> URL {
        let base = Self.timestamp(for: date)
        var candidate = directory.appendingPathComponent("rec-\(base).wav")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("rec-\(base)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// ISO 8601 基本格式时间戳（纯函数，单测覆盖）：`YYYYMMDDTHHMMSS.mmmZ`。
    /// 先取整到毫秒再分解（直接读 nanosecond 有浮点截断毛刺），进位安全。
    static func timestamp(for date: Date) -> String {
        let totalMs = Int((date.timeIntervalSince1970 * 1000).rounded())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(totalMs) / 1000))
        return String(
            format: "%04d%02d%02dT%02d%02d%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, totalMs % 1000)
    }

    // MARK: - 文件操作

    /// 把外部临时文件移入正式目录（FR-002：录音直写后归档）。
    /// 返回归档后的 URL；同源名冲突时按命名规则加序号。
    @discardableResult
    func move(intoStore source: URL) throws -> URL {
        let destination = makeRecordingURL(
            date: FileManager.default.creationDateOfItemOrDefault(at: source))
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// 删除文件（FR-012 删除条目连带清理；文件不存在不视为错误）。
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 按删除重载：字符串路径版——相对名（entries.audio_path）经存储目录解析；
    /// 删除目标必须落在录音目录内（2026-10-06 评审加固：DB 值被篡改/异常写入时，
    /// 目录外绝对路径与 `../` 逃逸相对路径记日志拒删，不让删除越出本 store）；
    /// 文件不存在不视为错误。
    func delete(path: String) {
        guard let target = containedDeletionTarget(for: path) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// 删除目标解析 + 目录边界校验：先按既有约定解析（相对名入目录 / 绝对路径原样），
    /// 再要求标准化路径以「存储目录/」为前缀；越界返回 nil（调用方跳过并已有日志）。
    private func containedDeletionTarget(for path: String) -> URL? {
        let target = resolve(path: path) ?? (path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.appendingPathComponent(path))
        let dirPath = directory.standardizedFileURL.path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        guard target.standardizedFileURL.path.hasPrefix(prefix) else {
            AppLog.audio.error("refused audio deletion outside store: \(path, privacy: .public)")
            return nil
        }
        return target
    }

    /// 存储路径（entries.audio_path）反解为绝对 URL。
    /// 约定：存相对文件名（目录可迁移）；容错：绝对路径原样返回、不存在返回 nil。
    func resolve(path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { // 绝对路径（含目录成分）
            let asURL = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: asURL.path) ? asURL : nil
        }
        let joined = directory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: joined.path) ? joined : nil
    }

    // MARK: - 大小预判（PRD §11：音频 > 10MB 编码后 → 发送前校验）

    /// 编码后大小预判：Base64 膨胀 4/3，即 秒数 × 32000 × 4/3 B/s ≈ 0.0427 MB/s。
    /// roadmap 公式 `durationMs × 0.0427MB/s × 4/3` 中的 0.0427 已含膨胀因子时存在
    /// 重复计算歧义，此处按原始字节 × 4/3 的明确推导实现（256000/3 B/s = 0.0427MB/s 十进制）。
    static func encodedByteEstimate(durationMs: Int) -> Double {
        Double(durationMs) / 1000.0 * wavBytesPerSecond * 4.0 / 3.0
    }

    /// 超限判定（发送前调用；正常情况下 maxRecordingSeconds=180 兜底不会触发）。
    static func isLikelyOverLimit(durationMs: Int) -> Bool {
        encodedByteEstimate(durationMs: durationMs) > Double(encodedByteLimit)
    }

    /// 过期音频清理（FR-018/TASK-035）：只删文件不动 DB 行。
    /// - Parameters:
    ///   - retentionDays: 保留天数（0 = 永久，直接返回空结果）。
    ///   - expiredAudioPaths: 已过期的 (audioPath) 列表——由调用方按成功条目的
    ///     created_at + 保留期算出（失败/取消条目不参与，PRD §11）。
    /// - Returns: 实际删掉的文件名（供日志/测试断言）。
    @discardableResult
    func cleanupExpiredAudio(paths: [String]) -> [String] {
        var removed: [String] = []
        for path in paths {
            guard let target = containedDeletionTarget(for: path),
                  FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.removeItem(at: target)
            removed.append(path)
            AppLog.audio.notice("expired audio removed: \(path, privacy: .public)")
        }
        return removed
    }
}

private extension FileManager {
    /// 取文件创建日期；失败（或无属性）回退当前时间（命名只求唯一与排序）。
    func creationDateOfItemOrDefault(at url: URL) -> Date {
        if let attrs = try? attributesOfItem(atPath: url.path),
           let date = attrs[.creationDate] as? Date {
            return date
        }
        return Date()
    }
}
