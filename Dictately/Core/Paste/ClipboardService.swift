import AppKit

/// 剪贴板写入（PRD FR-005①）：NSPasteboard .string 类型；
/// 返回写入后的 changeCount（供粘贴校验尽力而为地参考）。
final class ClipboardService {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// 清空并写入文本（String representation）。
    @discardableResult
    func write(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.pipeline.debug("clipboard written, \(text.count) chars")
        return pasteboard.changeCount
    }

    /// 当前 changeCount（PasteInjector 校验基线用）。
    var changeCount: Int { pasteboard.changeCount }

    /// 读取当前文本（校验/测试用）。
    func readString() -> String? {
        pasteboard.string(forType: .string)
    }
}
