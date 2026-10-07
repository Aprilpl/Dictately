import SwiftUI

/// 主窗口左侧边栏（v2-glass `AppShell` 逐项转录）：七项**纯文字**导航
/// （常规设置/听写模型/AI 服务/AI提示/历史记录/快捷键/关于，全部内嵌主窗口）；
/// 底部 App 图标 + 名称 + tagline「说完，字就在。」。
/// 视觉：sideBg 底、选中项 navOn 圆角底 + 左缘 2.5pt 品牌蓝指示条、DICTATELY 字标。
struct Sidebar: View {
    @Binding var selection: RootView.Page

    /// 七项导航（v2-glass Sidebar.items 同键序；原型 nav 行无图标）。
    private let items: [(page: RootView.Page, labelKey: LocalizedStringKey)] = [
        (.general, "sidebar.general"),
        (.models, "sidebar.models"),
        (.ai, "sidebar.ai"),
        (.prompts, "sidebar.prompts"),
        (.history, "sidebar.history"),
        (.hotkeys, "sidebar.hotkeys"),
        (.about, "sidebar.about"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            ForEach(items, id: \.page) { item in
                navRow(labelKey: item.labelKey, active: selection == item.page) {
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
    private func navRow(labelKey: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(labelKey)
                    .font(.system(size: 15, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text1 : Theme.text2)
                Spacer(minLength: 0)
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
