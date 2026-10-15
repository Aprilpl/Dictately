import AppKit
import SwiftUI

/// 全控多行文本（scrollview + 纯文本 NSTextView）。内边距常量暴露给 placeholder
/// 对齐：textContainerInset 原点 = 首行文字原点（lineFragmentPadding 置零消默认 5pt）。
/// TASK-086 自快捷键页抽出共享：听写测试框与风格编辑页 Prompt 大输入共用——
/// macOS `TextField(axis: .vertical) + lineLimit` 封顶不内滚（超长文本尾部不可见），
/// 本组件是站内可滚多行编辑的唯一正确实现，勿再用 SwiftUI 原生多行替代。
struct PlainTextEditor: NSViewRepresentable {
    static let insetX: CGFloat = 10
    static let insetY: CGFloat = 8

    @Binding var text: String
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlainTextView()
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor(Theme.text1) // 动态色：随浅/深主题
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        // 逐字保留文本（测试板转写 / Prompt 模板的弯引号、反引号、占位符都不得被替换）
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: Self.insetX, height: Self.insetY)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlainTextView else { return }
        textView.focusCallback = onFocusChange
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// 焦点回调载体：become/resign 第一响应者时上报（驱动外层 focus ring）。
final class PlainTextView: NSTextView {
    var focusCallback: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusCallback?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusCallback?(false) }
        return accepted
    }
}
