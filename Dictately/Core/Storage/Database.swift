import Foundation
import GRDB

/// GRDB 数据库初始化与迁移（PRD §3 Data Model）。
/// 库文件：`~/Library/Application Support/Dictately/dictately.sqlite`（父目录自动创建）；
/// 测试可注入自定义路径（临时目录）或 nil（内存库）。迁移用 DatabaseMigrator（migration id "v1"），
/// 后续版本只增不改已发布的 migration。
final class AppDatabase {
    /// 迁移完成后的数据库队列；Repository 与 UI 共用此实例。
    let dbQueue: DatabaseQueue

    /// 打开默认位置的库（生产路径）。
    static func openDefault() throws -> AppDatabase {
        try AppDatabase(path: defaultPath())
    }

    /// 默认库文件路径：~/Library/Application Support/Dictately/dictately.sqlite（PRD §3）。
    static func defaultPath() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Dictately", isDirectory: true)
            .appendingPathComponent("dictately.sqlite", isDirectory: false)
    }

    /// 打开指定路径的库并跑迁移；path 为 nil 时用内存库（测试）。
    init(path: URL?) throws {
        if let path {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path.path)
        } else {
            dbQueue = try DatabaseQueue() // :memory:
        }
        try Self.migrator.migrate(dbQueue)
        // notice（默认级别）会持久化到统一日志，`log show` 可查；info/debug 仅内存。
        AppLog.db.notice("database ready: \(path?.lastPathComponent ?? ":memory:", privacy: .public)")
    }

    /// v1：按 PRD §3 SQL 建 entries/styles 两表 + 三个索引。
    /// 表结构用 PRD 原文 SQL（列名/默认值逐字一致）；styles 先建以满足 entries.style_id 外键引用，
    /// 外键 ON DELETE SET NULL 来自 PRD §3 Relationships（删除风格置空历史引用，不删条目）。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE styles (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  tags TEXT,
                  description TEXT,
                  prompt TEXT NOT NULL,
                  is_builtin INTEGER NOT NULL DEFAULT 0,
                  hotkey INTEGER,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  sort_order INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE entries (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  created_at REAL NOT NULL,
                  type TEXT NOT NULL DEFAULT 'dictation',
                  style_id INTEGER,
                  status TEXT NOT NULL,
                  error_kind TEXT,
                  error_message TEXT,
                  audio_path TEXT,
                  audio_duration_ms INTEGER,
                  raw_text TEXT,
                  final_text TEXT,
                  asr_model TEXT,
                  asr_latency_ms INTEGER,
                  llm_model TEXT,
                  llm_latency_ms INTEGER,
                  pasted INTEGER NOT NULL DEFAULT 0,
                  FOREIGN KEY (style_id) REFERENCES styles(id) ON DELETE SET NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_entries_created ON entries(created_at DESC)")
            try db.execute(sql: "CREATE INDEX idx_entries_status  ON entries(status)")
            try db.execute(sql: "CREATE INDEX idx_entries_type    ON entries(type)")
        }
        // v2（2026-10-01 裁决 #12）：风格热键从写死槽位整数（hotkey = 1|2）升级为任意组合串
        // （如 "cmd+18"）。旧 hotkey 列保留休眠不映射（只增不改已发布 migration）；
        // 存量数据搬运由 StyleRepository.backfillHotkeyCombos 守卫迁移承担（可单测）。
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE styles ADD COLUMN hotkey_combo TEXT")
        }
        // v3（TASK-150 文件转写）：独立历史表——与听写 entries 语义分离，
        // 使用统计页口径零改动（2026-10-24 用户裁决：文件转写永不计入统计）。
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE file_transcripts (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  created_at REAL NOT NULL,
                  file_name TEXT NOT NULL,
                  file_ext TEXT NOT NULL,
                  file_size_bytes INTEGER NOT NULL,
                  duration_ms INTEGER,
                  audio_path TEXT,
                  mode TEXT NOT NULL,
                  model_id TEXT NOT NULL,
                  model_name TEXT NOT NULL,
                  status TEXT NOT NULL,
                  text TEXT,
                  summary TEXT,
                  error_kind TEXT,
                  error_message TEXT,
                  transcribe_ms INTEGER,
                  completed_at REAL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_file_transcripts_created ON file_transcripts(created_at DESC)")
        }
        return migrator
    }
}
