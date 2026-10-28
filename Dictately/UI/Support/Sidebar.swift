import SwiftUI

/// 主窗口左侧边栏（v2-glass `AppShell` 逐项转录）：七项**纯文字**导航
/// （常规设置/听写模型/AI 服务/AI提示/历史记录/快捷键/关于，全部内嵌主窗口）；
/// 底部 App 图标 + 名称 + tagline「说完，字就在。」。
/// 视觉：sideBg 底、选中项 navOn 圆角底 + 左缘 2.5pt 品牌蓝指示条、DICTATELY 字标。
struct Sidebar: View {
    @Binding var selection: RootView.Page
    /// 文件转写运行徽标（TASK-150）：运行中显示实时百分比「NN%」；静止为 nil
    /// （2026-10-24 用户裁决：无「新」徽标）。
    var transcribeBadge: String?
    /// 文件转写失败徽标（2026-10-25 用户裁决）：有失败未回看且不在运行中 →
    /// 红色三角感叹号 chip（百分比优先；进转写页即清）。
    var transcribeFailure: Bool = false

    /// 九项导航（v2-glass Sidebar.items 键序 + TASK-133 使用统计；2026-10-15 用户
    /// 裁决使用统计与快捷键对调；TASK-150 文件转写插入 AI 提示之下、历史记录之上；
    /// 原型 nav 行无图标）。
    private let items: [(page: RootView.Page, labelKey: LocalizedStringKey)] = [
        (.general, "sidebar.general"),
        (.models, "sidebar.models"),
        (.ai, "sidebar.ai"),
        (.prompts, "sidebar.prompts"),
        (.transcribe, "sidebar.transcribe"),
        (.history, "sidebar.history"),
        (.usage, "sidebar.usage"),
        (.hotkeys, "sidebar.hotkeys"),
        (.about, "sidebar.about"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            ForEach(items, id: \.page) { item in
                navRow(
                    labelKey: item.labelKey, active: selection == item.page,
                    badge: item.page == .transcribe ? transcribeBadge : nil,
                    badgeFailure: item.page == .transcribe ? transcribeFailure : false
                ) {
                    selection = item.page
                }
            }
            Spacer(minLength: 0)
            brandFooter
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: 210) // TASK-077 用户裁决 210pt（PRD §8 允许 180–220pt）
        .background(Theme.sideBg)
    }

    /// 顶部字标（v2-glass：12px t3 + 字距，左对齐——TASK-078 用户追裁居中版难看，恢复原排布）。
    private var navHeader: some View {
        Text("DICTATELY")
            .font(.system(size: 12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }

    /// 导航行（v2-glass ray-nav）：TASK-077 用户裁决 15pt 字号 + 行距加大
    /// （行内 vertical 8→10 / 行间距 2→6）；TASK-078 用户追裁居中版难看——
    /// 文字恢复左对齐（HStack + Spacer 原结构）。选中 = navOn 底 + t1
    /// semibold + 左缘 2.5pt 品牌蓝条；纯文字无图标（原型同款）。
    /// 徽标两态（2026-10-25 用户裁决）：运行百分比 chip（蓝）优先；无百分比且
    /// badgeFailure（文件转写有失败未回看）→ 红色三角感叹号 chip。
    private func navRow(
        labelKey: LocalizedStringKey, active: Bool, badge: String? = nil,
        badgeFailure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(labelKey)
                    .font(.system(size: 15, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text1 : Theme.text2)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.blueTintBg))
                        .overlay(Capsule().strokeBorder(Theme.blueTintBorder, lineWidth: 0.5))
                } else if badgeFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.err)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Theme.redTintBg))
                        .overlay(Capsule().strokeBorder(Theme.redTintBorder, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.navOn : .clear))
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.blue)
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
    }

    /// 底部品牌区：App 图标 + 名称 + tagline（PRD §8 逐字文案）。
    private var brandFooter: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("app.name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("app.tagline")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}
