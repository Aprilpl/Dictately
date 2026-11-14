import SwiftUI
import AppKit

struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line2, lineWidth: 0.5))
    }
}

/// 编辑态输入框（2026-10-01 用户裁决的统一交互，自温度控件推广全站设置值输入）：
/// - 未聚焦 = 无边框纯文本（当前值/灰 placeholder），不呈输入框；
/// - 点击聚焦 = 玻璃底输入框 + 品牌蓝 focus ring；
/// - 回车（onSubmit）/ 鼠标移开（onHover）/ 焦点转移 = 退出编辑恢复纯文本
///   （点击窗口空白 macOS 不转移焦点，必须显式退出路径）；
/// - `invalid` = 值非法提示（红边，聚焦与否均显示——与蓝框互斥优先蓝框）。
struct GlassField: View {
    var placeholder: LocalizedStringKey
    @Binding var text: String
    /// 密钥类输入（SecureField 圆点显示）。
    var isSecure = false
    var width: CGFloat? = nil
    /// mono 字体（URL/Key/模型名/数值类输入）。
    var monospaced = true
    /// 文字对齐（默认 leading；数值短框可用 trailing 贴值列右缘，与相邻下拉值同列）。
    var textAlignment: TextAlignment = .leading
    var invalid = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        isSecure: Bool = false,
        width: CGFloat? = nil,
        monospaced: Bool = true,
        textAlignment: TextAlignment = .leading,
        invalid: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.width = width
        self.monospaced = monospaced
        self.textAlignment = textAlignment
        self.invalid = invalid
        self.onSubmit = onSubmit
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(monospaced ? Theme.mono(12.5) : .system(size: 13))
            .multilineTextAlignment(textAlignment)
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(Group { if focused { FieldBackground() } else { Color.clear } })
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1))
            .focused($focused)
            .onSubmit {
                focused = false
                onSubmit?()
            }
            .onHover { hovering in
                if !hovering { focused = false }
            }
            .animation(.easeInOut(duration: 0.15), value: focused)
    }

    @ViewBuilder private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var borderColor: Color {
        if focused { return Theme.blueTintBorder }
        return invalid ? Theme.redTintBorder : .clear
    }
}

// MARK: - 统一提示横幅（TASK-043：一行原因 + 可选动作按钮，全 App 错误/警示同构）

/// 语义横幅：warn（橙）/ error（红）/ success（绿）三种色调，图标 + 主行 + 可选副行 +
/// 可选动作按钮。PRD §11 各错误场景的 UI 呈现统一走这里（面板胶囊内除外）。
struct NoticeBanner: View {
    enum Tone { case warn, error, success }

    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    var tone: Tone = .warn

    /// 动态文案便捷入口（错误消息已是用户可读文本，不做键查找）。
    init(
        title message: String,
        subtitle: String? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        tone: Tone = .warn
    ) {
        self.title = LocalizedStringKey(message)
        self.subtitle = subtitle.map { LocalizedStringKey($0) }
        self.actionTitle = actionTitle
        self.action = action
        self.tone = tone
    }

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        tone: Tone = .warn
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(accent)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(border, lineWidth: 1))
    }

    private var icon: String {
        switch tone {
        case .warn, .error: return "⚠"
        case .success: return "✓"
        }
    }

    private var accent: Color {
        switch tone {
        case .warn: return Theme.warn
        case .error: return Theme.err
        case .success: return Theme.ok
        }
    }

    private var bg: Color {
        switch tone {
        case .warn: return Theme.orangeTintBg
        case .error: return Theme.failBannerBg
        case .success: return Theme.greenTintBg
        }
    }

    private var border: Color {
        switch tone {
        case .warn: return Theme.orangeTintBorder
        case .error: return Theme.failBannerBorder
        case .success: return Theme.greenTintBorder
        }
    }
}
