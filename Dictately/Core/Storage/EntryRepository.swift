import Foundation
import GRDB

/// 听写/风格历史条目（PRD §3 entries 表，列名 snake_case 映射）。
/// Phase 0 骨架：字段全覆盖建模；查询/分页/搜索能力 Phase 3（TASK-031）补全。
struct Entry: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "entries"

    /// 条目类型（type 列）：'dictation' | 'style'（经 LLM 润色）。
    enum Kind: String, Codable {
        case dictation, style
    }

    /// 条目状态（status 列）：'success' | 'failed' | 'cancelled'。
    enum Status: String, Codable {
        case success, failed, cancelled
    }

    var id: Int64?
    /// Unix 秒（含小数）。
    var createdAt: Double
    var type: Kind
    /// type='style' 时的风格 id；可空（风格被删后 SET NULL，PRD §3 Relationships）。
    var styleId: Int64?
    var status: Status
    /// 失败时的错误分类名（ASRError/LLMError）。
    var errorKind: String?
    var errorMessage: String?
    /// 相对 AudioFileStore 目录的文件名。
    var audioPath: String?
    var audioDurationMs: Int?
    /// ASR 原始转写（失败时可为空）。
    var rawText: String?
    /// 最终产出（无润色时 = rawText）。
    var finalText: String?
    var asrModel: String?
    var asrLatencyMs: Int?
    var llmModel: String?
    var llmLatencyMs: Int?
    /// 是否成功粘贴（false=仅复制/手动）。
    var pasted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case type
        case styleId = "style_id"
        case status
        case errorKind = "error_kind"
        case errorMessage = "error_message"
        case audioPath = "audio_path"
        case audioDurationMs = "audio_duration_ms"
        case rawText = "raw_text"
        case finalText = "final_text"
        case asrModel = "asr_model"
        case asrLatencyMs = "asr_latency_ms"
        case llmModel = "llm_model"
        case llmLatencyMs = "llm_latency_ms"
        case pasted
    }

    init(
        id: Int64? = nil,
        createdAt: Double,
        type: Kind = .dictation,
        styleId: Int64? = nil,
        status: Status,
        errorKind: String? = nil,
        errorMessage: String? = nil,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        rawText: String? = nil,
        finalText: String? = nil,
        asrModel: String? = nil,
        asrLatencyMs: Int? = nil,
        llmModel: String? = nil,
        llmLatencyMs: Int? = nil,
        pasted: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.styleId = styleId
        self.status = status
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.audioPath = audioPath
        self.audioDurationMs = audioDurationMs
        self.rawText = rawText
        self.finalText = finalText
        self.asrModel = asrModel
        self.asrLatencyMs = asrLatencyMs
        self.llmModel = llmModel
        self.llmLatencyMs = llmLatencyMs
        self.pasted = pasted
    }

    /// 插入后回填自增 id（MutablePersistableRecord）。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 查询描述（TASK-031 / FR-011）：类型筛选 + 状态筛选 + 关键词（raw/final 模糊）
/// + 排序方向 + 分页。值类型，列表页直接构造。
struct EntryQuery: Equatable {
    /// 状态筛选（TASK-097，2026-10-03 用户裁决：可筛成功也可筛失败，替换 onlyFailed）：
    /// rawValue 直通 status 列；cancelled 行两种筛选都不命中（边界可接受）。
    enum Status: String {
        case ok = "success"
        case failed = "failed"
    }

    var type: Entry.Kind?
    var status: Status?
    var keyword: String?
    /// false = 最新在前（默认列表序）；true = 最早在前。
    var ascending = false
    var limit = 50
    var offset = 0

    init(
        type: Entry.Kind? = nil, status: Status? = nil,
        keyword: String? = nil, ascending: Bool = false,
        limit: Int = 50, offset: Int = 0
    ) {
        self.type = type
        self.status = status
        self.keyword = keyword
        self.ascending = ascending
        self.limit = limit
        self.offset = offset
    }
}

/// 历史条目仓库：insert/fetchAll（骨架）+ 分页/筛选/搜索/删除（TASK-031 补全）。
final class EntryRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// 库是否落盘（内存库时 false——孤儿恢复扫描须以此跳过，见 AppDatabase.isOnDisk）。
    var isOnDisk: Bool { database.isOnDisk }

    /// 插入条目，返回带自增 id 的落库实例。
    @discardableResult
    func insert(_ entry: Entry) throws -> Entry {
        var copy = entry
        try database.dbQueue.write { db in
            try copy.insert(db)
        }
        return copy
    }

    /// 全量读取（按 created_at DESC、id DESC——与 idx_entries_created 一致的默认列表序）。
    func fetchAll() throws -> [Entry] {
        try database.dbQueue.read { db in
            try Entry.order(Column("created_at").desc, Column("id").desc).fetchAll(db)
        }
    }

    /// 按 id 取单条（重试链路更新前先取原值）。
    func fetch(id: Int64) throws -> Entry? {
        try database.dbQueue.read { db in
            try Entry.filter(Column("id") == id).fetchOne(db)
        }
    }

    // MARK: - 查询（TASK-031 / FR-011）

    /// 分页查询：created_at DESC/ASC + id 兜底稳定序；keyword 对 raw/final LIKE
    /// （%/_/\\ 转义，PRD 验收「转义 %_」）；状态筛选叠加在类型筛选之上。
    func fetchPage(_ query: EntryQuery) throws -> [Entry] {
        try database.dbQueue.read { db in
            let request = Self.baseRequest(query)
                .order(Self.ordering(ascending: query.ascending))
                .limit(query.limit, offset: query.offset)
            return try request.fetchAll(db)
        }
    }

    /// 符合筛选条件的总条数（分页页数计算；忽略 limit/offset）。
    func count(matching query: EntryQuery) throws -> Int {
        try database.dbQueue.read { db in
            try Self.baseRequest(query).fetchCount(db)
        }
    }

    /// 组装筛选（类型 + 状态 + 关键词）。
    private static func baseRequest(_ query: EntryQuery) -> QueryInterfaceRequest<Entry> {
        var request = Entry.all()
        if let type = query.type {
            request = request.filter(Column("type") == type.rawValue)
        }
        if let status = query.status {
            request = request.filter(Column("status") == status.rawValue)
        }
        let keyword = query.keyword?.trimmingCharacters(in: .whitespaces) ?? ""
        if !keyword.isEmpty {
            let pattern = "%" + escapeLike(keyword) + "%"
            let rawMatch = Column("raw_text").like(pattern, escape: likeEscape)
            let finalMatch = Column("final_text").like(pattern, escape: likeEscape)
            request = request.filter(rawMatch || finalMatch)
        }
        return request
    }

    private static func ordering(ascending: Bool) -> [SQLOrderingTerm] {
        ascending
            ? [Column("created_at").asc, Column("id").asc]
            : [Column("created_at").desc, Column("id").desc]
    }

    /// 成功条目中，创建时间早于 cutoff 的 audio 文件名（FR-018 清理输入；
    /// 失败/取消条目音频不受保留期限制——PRD §11 原文）。
    func audioPathsOfStaleSuccessEntries(olderThan cutoff: Date) throws -> [String] {
        try database.dbQueue.read { db in
            let request = Entry
                .filter(Column("status") == Entry.Status.success.rawValue)
                .filter(Column("created_at") < cutoff.timeIntervalSince1970)
            return try request.fetchAll(db).compactMap(\.audioPath)
        }
    }

    /// 删除条目，返回其 audio 文件名（调用方据此清理音频文件，PRD FR-012）。
    @discardableResult
    func delete(id: Int64) throws -> String? {
        try database.dbQueue.write { db in
            guard let entry = try Entry.fetchOne(db, key: id) else { return nil }
            try entry.delete(db)
            return entry.audioPath
        }
    }

    /// LIKE 转义字符（反斜杠，配合 ESCAPE 子句）。
    static let likeEscape = "\\"

    /// LIKE 通配符转义：%/_/\ 前加反斜杠（配合 ESCAPE '\'）。
    static func escapeLike(_ keyword: String) -> String {
        var escaped = String()
        for character in keyword {
            if character == "%" || character == "_" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// 更新条目（重试成功/失败后原地更新同一行，FR-013：重试更新状态而非新插一行）。
    @discardableResult
    func update(_ entry: Entry) throws -> Entry {
        try database.dbQueue.write { db in
            try entry.update(db)
        }
        return entry
    }
}
