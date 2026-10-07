import Foundation
import os

/// os.Logger 统一封装（PRD FR-006：subsystem "com.dictately"；§7：日志不记录转写文本全文）。
/// category 按域划分，Console.app 按 subsystem 过滤即可看到全部日志：
/// - pipeline：听写链路与阶段计时汇总
/// - hotkey：CGEventTap 热键事件
/// - audio：录音/编码
/// - db：存储初始化与异常
///
/// 级别约定：需要 `log show` 事后排查的用 notice（默认级，持久化）；
/// 高频流水用 info/debug（仅内存，`log stream` 实时可见）。
enum AppLog {
    static let subsystem = "com.dictately"

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let app = Logger(subsystem: subsystem, category: "app")
}
