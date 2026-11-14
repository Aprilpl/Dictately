import SwiftUI
import AppKit

struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - 通用组件（v2-glass 原子：Chip / TypeBadge / StatusMark / Kbd / SettingRow / Segmented）

/// 语义色调小徽标（glassStyles.chip + Chip tones）。
struct Chip: View {
    enum Tone { case neutral, blue, green, red, orange, brand, dim }

    let text: String
    var tone: Tone = .neutral
    /// 覆盖字体（mono 模型名 chip 等场景）；nil = 默认 12pt medium。
    var font: Font?
    /// 内距覆盖（TASK-142：bench 卡片紧凑 chips 6×1.5 / 8×1.5）；缺省 7×2 不变。
    var paddingH: CGFloat = 7
    var paddingV: CGFloat = 2

    var body: some View {
        Text(text)
            .font(font ?? .system(size: 12, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 1))
    }

    private var fg: Color {
        switch tone {
        case .neutral, .blue: Theme.text2
        case .green: Theme.ok
        case .red: Theme.err
        case .orange: Theme.warn
        case .brand: Theme.blue
        case .dim: Theme.text3
        }
    }

    private var bg: Color {
        switch tone {
        case .neutral, .dim: Theme.fillSoft
        case .blue, .brand: Theme.blueTintBg
        case .green: Theme.greenTintBg
        case .red: Theme.redTintBg
        case .orange: Theme.orangeTintBg
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral, .dim: Theme.line
        case .blue, .brand: Theme.blueTintBorder
        case .green: Theme.greenTintBorder
        case .red: Theme.redTintBorder
        case .orange: Theme.orangeTintBorder
        }
    }
}

/// 类型徽标：风格 = 品牌蓝调；听写 = 中性（TypeBadge）。
struct TypeBadge: View {
    let isStyle: Bool

    var body: some View {
        Chip(text: isStyle ? "风格" : "听写", tone: isStyle ? .blue : .neutral)
    }
}

/// 状态标：成功 ✓（ok 绿）/ 失败 ⚠（warn 橙）（StatusMark，符号制不用 emoji）。
struct StatusMark: View {
    let isOK: Bool

    var body: some View {
        Text(isOK ? "✓" : "⚠")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isOK ? Theme.ok : Theme.warn)
            .frame(width: 16)
    }
}

/// kbd 键帽（本方向签名细节）：SF Mono + 发丝边 + 微立体。
struct KbdKey: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(Theme.mono(size))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize() // 键帽原子性：空间不足时整体不被压缩（bug00010 残留：Esc 被挤成竖排两行）
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.dyn(light: .white.withAlphaComponent(0.55), dark: .white.withAlphaComponent(0.08))))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Theme.dyn(light: .white.withAlphaComponent(0.75), dark: .white.withAlphaComponent(0.16)),
                        lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
            // 键帽是功能标签（Esc/⌘+1）：读屏按原文读，避免只剩一串符号（TASK-177）。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// 设置行：label + hint 左，控件右，底部分隔线（SettingRow）。
