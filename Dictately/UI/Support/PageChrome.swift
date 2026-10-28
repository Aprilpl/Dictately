import SwiftUI

// MARK: - 设置类页面骨架共享件（§85 收敛——此前页头 5 份、节标签 3 份、值列 2 份逐字节
// 相同的私有实现散布各页；数值均为 TASK-077~082 排印终值，勿改勿「统一」）

/// 页头（标题 + 副标题）：常规/快捷键/AI 服务/听写模型/使用统计五页同款。
/// 标题 15.5 bold text1、副标题 12.5 text3 + 行距 4（TASK-082 标题↔副标题 3→6）。
/// 文件转写页头形态不同（无行距、底部 24、右侧动作钮），不在此列。
struct PageHeader: View {
    let titleKey: LocalizedStringKey
    let descKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text(descKey)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }
}

/// 卡片组上方小节标签（三页同款）：13.5 semibold tracking 1 text3、标签→卡片 16
/// （TASK-082 追裁 12→13.5、8→16）；上方间距随各节裁决由调用点传入。
struct SectionLabel: View {
    let key: LocalizedStringKey
    let topPadding: CGFloat

    init(_ key: LocalizedStringKey, topPadding: CGFloat) {
        self.key = key
        self.topPadding = topPadding
    }

    var body: some View {
        Text(key)
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.top, topPadding)
            .padding(.bottom, 16)
    }
}

/// 值列块：卡内行控件统一放进同宽左对齐块，共享同一条左缘线
/// （2026-10-01 用户裁决「左对齐」；宽度 = Theme.valueColumnWidth）。
func valueColumn<V: View>(_ view: V) -> some View {
    view.frame(width: Theme.valueColumnWidth, alignment: .leading)
}
