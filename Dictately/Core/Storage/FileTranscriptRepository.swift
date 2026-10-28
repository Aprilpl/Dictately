import Foundation
import GRDB

/// 文件转写历史条目（TASK-150，file_transcripts 表；与听写 entries 语义分离，
/// 使用统计口径零改动——2026-10-24 用户裁决：文件转写永不计入统计）。
struct FileTranscript: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "file_transcripts"

    /// 引擎模式（mode 列）：'api' | 'local'。
    enum Mode: String, Codable {
        case api, local
    }

    /// 条目状态（status 列）：'running' | 'succeeded' | 'failed'。
    enum Status: String, Codable {
        case running, succeeded, failed

        /// App 重启后 running 行无对应任务——归一为失败（中断）。
        static let interruptedFallback = failed
    }

    var id: Int64?
    /// Unix 秒（含小数）。
    var createdAt: Double
    /// 原始文件名（含扩展名，展示用）。
    var fileName: String
    /// 扩展名小写（无点；'mp3'/'wav'/'m4a'）。
    var fileExt: String
    var fileSizeBytes: Int64
    var durationMs: Int?
    /// 相对 AudioFileStore 目录的文件名（导入拷贝产物，删除条目连带清理）。
    var audioPath: String?
    var mode: Mode
    /// API=provider rawValue；本地=模型 repo id。
    var modelID: String
    /// 展示名（API=供应商显示名；本地=模型显示名）。
    var modelName: String
    var status: Status
    var text: String?
    /// AI 摘要原文（bullet 行渲染在视图层解析）。
    var summary: String?
    /// 失败分类（ASRError.kindKey / cancelled / interrupted / importFailed）。
    var errorKind: String?
    var errorMessage: String?
    var transcribeMs: Int?
    var completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case fileName = "file_name"
        case fileExt = "file_ext"
        case fileSizeBytes = "file_size_bytes"
        case durationMs = "duration_ms"
        case audioPath = "audio_path"
        case mode
        case modelID = "model_id"
        case modelName = "model_name"
        case status
        case text
        case summary
        case errorKind = "error_kind"
        case errorMessage = "error_message"
        case transcribeMs = "transcribe_ms"
        case completedAt = "completed_at"
    }

    init(
        id: Int64? = nil,
        createdAt: Double,
        fileName: String,
        fileExt: String,
        fileSizeBytes: Int64,
        durationMs: Int? = nil,
        audioPath: String? = nil,
        mode: Mode,
        modelID: String,
        modelName: String,
        status: Status,
        text: String? = nil,
        summary: String? = nil,
        errorKind: String? = nil,
        errorMessage: String? = nil,
        transcribeMs: Int? = nil,
        completedAt: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.fileExt = fileExt
        self.fileSizeBytes = fileSizeBytes
        self.durationMs = durationMs
        self.audioPath = audioPath
        self.mode = mode
        self.modelID = modelID
        self.modelName = modelName
        self.status = status
        self.text = text
        self.summary = summary
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.transcribeMs = transcribeMs
        self.completedAt = completedAt
    }

    /// 插入后回填自增 id（MutablePersistableRecord）。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 文件转写历史列表轻量行（TASK-158）：面板行 + hist 分支判定所需列
/// （详情文本经 FileTranscribeController.viewingDetail 按需取全行）。
struct FileTranscriptListItem: Identifiable, Equatable {
    let id: Int64
    let createdAt: Double
    let fileName: String
    let modelName: String
    let status: FileTranscript.Status
    let errorKind: String?
}

/// 文件转写历史仓库：insert/update/fetchAll/delete + 启动归一（running → 中断失败）。
/// 模式照 EntryRepository（GRDB 记录 + 单写事务）。
final class FileTranscriptRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    func insert(_ entry: FileTranscript) throws -> FileTranscript {
        var copy = entry
        try database.dbQueue.write { db in
            try copy.insert(db)
        }
        return copy
    }

    @discardableResult
    func update(_ entry: FileTranscript) throws -> FileTranscript {
        try database.dbQueue.write { db in
            try entry.update(db)
        }
        return entry
    }

    /// 仅写摘要字段（AI 总结完成；避免覆盖转写主链路并发写入的其余列）。
    func updateSummary(id: Int64, summary: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE file_transcripts SET summary = ? WHERE id = ?",
                arguments: [summary, id])
        }
    }

    func fetchAll() throws -> [FileTranscript] {
        try database.dbQueue.read { db in
            try FileTranscript
                .order(Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    /// 历史列表轻量行（TASK-158）：右栏面板/hist 分支判定只需要小列——此前列表源
    /// fetchAll 全列物化 text/summary（实测 100 条 ×~200KB ≈ 41MB、58ms/次，
    /// 轻量列 423μs/次，随历史条数线性恶化）；详情经 fetch(id:) 按需取全行。
    func fetchListItems() throws -> [FileTranscriptListItem] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, created_at, file_name, model_name, status, error_kind
                FROM file_transcripts ORDER BY created_at DESC, id DESC
                """
            ).map { row in
                FileTranscriptListItem(
                    id: row["id"], createdAt: row["created_at"], fileName: row["file_name"],
                    modelName: row["model_name"],
                    status: FileTranscript.Status(rawValue: row["status"] ?? "") ?? .failed,
                    errorKind: row["error_kind"])
            }
        }
    }

    func fetch(id: Int64) throws -> FileTranscript? {
        try database.dbQueue.read { db in
            try FileTranscript.filter(Column("id") == id).fetchOne(db)
        }
    }

    /// 删除条目，返回其 audio 文件名（调用方据此清理音频文件，沿 EntryRepository.delete 语义）。
    @discardableResult
    func delete(id: Int64) throws -> String? {
        try database.dbQueue.write { db in
            guard let entry = try FileTranscript.fetchOne(db, key: id) else { return nil }
            try entry.delete(db)
            return entry.audioPath
        }
    }

    /// 启动归一：上次退出遗留的 running 行改为失败（errorKind=interrupted）。
    /// 返回受影响行数（供日志；0 = 无遗留）。
    @discardableResult
    func markInterrupted() throws -> Int {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE file_transcripts
                SET status = 'failed', error_kind = 'interrupted',
                    error_message = ?, completed_at = ?
                WHERE status = 'running'
                """,
                arguments: [Self.interruptedMessage, Date().timeIntervalSince1970])
            return db.changesCount
        }
    }

    /// 中断行统一错误文案（error_message 列；展示层直接使用）。
    static let interruptedMessage = "转写在应用退出时中断"
}
