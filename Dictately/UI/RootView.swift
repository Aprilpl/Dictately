import SwiftUI

/// 主窗口根视图（2026-10-01 用户裁决对齐 v2-glass `AppShell`：**设置内嵌主窗口**，
/// 七项侧栏统一导航——常规设置/听写模型/AI 服务/AI提示/历史记录/快捷键/关于；
/// 取代旧「主窗口历史/风格 + 独立设置窗口四 Tab」结构）。
/// 视觉（TASK-038，v2-glass 转录）：整窗毛玻璃底（GlassBackground），
/// 侧栏 sideBg + 右缘 line 分隔；内容区透明叠于玻璃之上。
struct RootView: View {
    /// 侧边栏七页（顺序即原型 AppShell 顺序）。String raw value 供 TASK-078
    /// 页记忆持久化（AppSettings.sidebarLastPage 存 rawValue）。
    enum Page: String, Hashable {
        case general, models, ai, prompts, history, hotkeys, about
    }

    // 无记忆值/非法存档的回退默认（2026-10-06 用户裁决：首装落在常规设置；
    // 存量用户的最后浏览页记忆优先，见 onAppear 恢复）。
    @State private var selection: Page = .general
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
            Rectangle().fill(Theme.line).frame(width: 0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GlassBackground())
        .frame(minWidth: 760, minHeight: 480)
        // TASK-097：全站动作 Toast——主窗口正中浮动（位置追裁，~1.6s 自动消失）。
        .overlay(alignment: .center) {
            if let message = environment.toast.current {
                ToastView(message: message)
                    .animation(.easeInOut(duration: 0.18), value: environment.toast.current)
            }
        }
        // TASK-077：主窗口位置+尺寸记忆（autosave 接缝详见 WindowFrameRestorer）。
        // background 放法不参与布局（零尺寸视图），只为拿 NSWindow。
        .background(WindowFrameRestorer())
        .onChange(of: environment.windowRouter.pendingPage) { _, _ in
            // 主窗口存活时的定位页请求（⌘, / 状态栏「设置…」）；消费清账再触发一次 nil，忽略。
            if let page = environment.windowRouter.consumePendingPage() {
                selection = page
            }
        }
        .onAppear {
            // TASK-078 页记忆：恢复最后浏览页（在 installRouter 之前——⌘, 等
            // pendingPage 显式定位优先覆盖本次恢复）；空/非法存档回退常规设置。
            if let last = Page(rawValue: environment.settings.sidebarLastPage) {
                selection = last
            }
            installRouter()
        }
        .onChange(of: selection) { _, page in
            // TASK-078：页切换即持久化（恢复动作触发的首次 onChange 写同值幂等）。
            environment.settings.sidebarLastPage = page.rawValue
        }
    }

    /// 灌入 WindowRouter（TASK-076：⌘, / 状态栏菜单在主窗口关闭后仍能重开）+
    /// 消费关窗期积压的定位页请求 + Debug `--page` 参数。
    private func installRouter() {
        environment.windowRouter.openWindowAction = openWindow
        if let page = environment.windowRouter.consumePendingPage() {
            selection = page
        }
        applyLaunchPageArgument()
    }

    /// Debug 自动化：`--page <general|models|ai|prompts|history|hotkeys|about>`
    /// 直接定位侧栏页（仅 Debug 编译进二进制；截图/走查脚本用）。
    private func applyLaunchPageArgument() {
        #if DEBUG
        guard let index = CommandLine.arguments.firstIndex(of: "--page"),
              index + 1 < CommandLine.arguments.count else { return }
        switch CommandLine.arguments[index + 1] {
        case "general": selection = .general
        case "models": selection = .models
        case "ai": selection = .ai
        case "prompts": selection = .prompts
        case "hotkeys": selection = .hotkeys
        case "about": selection = .about
        default: break // history = 默认
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .models: ASRSettingsView()
        case .ai: LLMSettingsView()
        case .prompts: StyleListView()
        case .history: HistoryView()
        case .hotkeys: HotkeySettingsView()
        case .about: AboutView()
        }
    }
}
