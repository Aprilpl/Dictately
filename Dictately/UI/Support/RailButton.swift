import SwiftUI

// MARK: - 卡片原子件（三处卡片共享：本地模型卡 + 两页供应商卡）
//
// TASK-146 自 LocalModelsSection.swift 抽出（原为该文件私有件）：供应商卡「使用」
// 文字按钮改图标语言后与本地卡共用同款图标钮。
// TASK-149（2026-10-15 用户裁决，原型 docs/design-demos/card-state-icons.html 方案 C
// 「槽位图章」定稿）：「✓ 使用中」文字 chip（InUseChip，蓝底白字）退役——激活卡在
// 「使用」图标钮的同一 34×34 槽位原地变 SlotSeal（淡蓝 tint 图章 + 蓝色对勾），
// 点「使用」→ 通过测试 → 按钮变图章，形变最小、槽位永驻不空；「已配置/未配置」
// 中性文字 chip 退役 → KeyBadge 钥匙徽（灰 = 已配置 / 橙 = 未配置），落供应商卡
// 底部 meta 行。整卡 softBlueTint 淡蓝激活载体（§72）不变。

/// 「使用中」槽位图章（原型 .slotseal）：34×34、cornerRadius 9——几何逐字节对齐
/// RailButton（非激活卡「使用」图标钮所在槽位）。文案键 models.inuse 转为 tooltip
/// 语义（值已去「✓ 」前缀）。
struct SlotSeal: View {
    var body: some View {
        PhIcon(name: .check, weight: .bold, size: 16)
            .foregroundStyle(Theme.blue)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.softBlueTintBg))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.softBlueTintBorder, lineWidth: 1))
            .help(String(localized: "models.inuse"))
    }
}

/// 钥匙状态徽（原型 .kbadge）：20×20 圆——ok = 中性灰底 + 灰钥匙；未配置 = 橙 tint
/// 底 + 橙钥匙。tooltip 走 models.provider.keyOk / needKey（两键已改 tooltip 语句）。
struct KeyBadge: View {
    let ok: Bool

    var body: some View {
        PhIcon(name: .key, size: 12)
            .foregroundStyle(ok ? Theme.text2 : Theme.warn)
            .frame(width: 20, height: 20)
            .background(Circle().fill(ok ? Theme.fillSoft : Theme.orangeTintBg))
            .overlay(Circle().strokeBorder(ok ? Theme.line : Theme.orangeTintBorder, lineWidth: 1))
            .help(String(localized: ok ? "models.provider.keyOk" : "models.provider.needKey"))
    }
}

/// 动作栏图标钮（原型 .ibtn 34×34 r9）：gray = 真灰实底 hover 提亮 12%；
/// ghostDanger = 描边幽灵，hover 边+图标变 Theme.err（删除）。transition .15s。
/// disabled = 禁用视觉 opacity 0.4（供应商卡页内他卡测试进行中时置灰，TASK-146）。
struct RailButton: View {
    enum Kind { case gray, ghostDanger }

    let icon: PhIconName
    let kind: Kind
    let helpText: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PhIcon(name: icon, size: 16)
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(kind == .gray ? Theme.grayBtnBg : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(borderColor, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brightness(hovering && kind == .gray && !disabled ? 0.12 : 0)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .help(helpText)
    }

    private var iconColor: Color {
        kind == .gray ? Theme.grayBtnFg : (hovering ? Theme.err : Theme.text2)
    }

    private var borderColor: Color {
        kind == .gray ? .clear : (hovering ? Theme.err : Theme.line2)
    }
}

/// 虚线分隔线（原型 border-top: 1px dashed）：本地模型卡下层与供应商卡 meta 行共用
/// （TASK-149 自 LocalModelsSection 私有件迁出共享）。
struct DashedDivider: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}
