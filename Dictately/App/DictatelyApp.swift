import SwiftUI

@main
struct DictatelyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 依赖容器：AppDelegate 持有（启动接线需要先于首帧就绪），App body 经此取用。
    private var environment: AppEnvironment { appDelegate.environment }

    var body: some Scene {
        // 统一主窗口（2026-10-01 对齐 v2-glass AppShell：设置内嵌主窗口七页导航；
        // 默认标题栏显示「Dictately」，原型 RayWindow 同款）
        WindowGroup("Dictately", id: "main") {
            RootView()
                .environment(environment)
                .onAppear { maybeShowOnboarding() }
        }
        .defaultSize(width: 960, height: 640) // PRD §8：主窗口尺寸基准
        .defaultPosition(.center) // TASK-077：首启/无位置存档时居中（此前级联落左上）
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘,（应用菜单「设置…」）：设置已内嵌主窗口 → 激活主窗口并定位常规设置页。
            // 走 WindowRouter（TASK-076）：主窗口关闭后 RootView 已销毁，通知链路无人接收。
            CommandGroup(replacing: .appSettings) {
                Button("settings.menu.title") {
                    environment.windowRouter.openMain(at: .general)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // 首次运行引导（FR-014 / SPEC 屏 F：640×480 模态；完成或跳过写 onboardingCompleted 后不再弹出）
        Window("Dictately", id: "onboarding") {
            OnboardingView()
                .environment(environment)
        }
        .defaultSize(width: 640, height: 480)
        .defaultPosition(.center) // TASK-077：与主窗同款居中（模态引导窗叠于主窗上方）
        .windowResizability(.contentSize)
    }

    @Environment(\.openWindow) private var openWindow

    /// 首启且未完成引导 → 打开引导窗（写 onboardingCompleted 后永不再弹）。
    private func maybeShowOnboarding() {
        guard !environment.settings.onboardingCompleted else { return }
        openWindow(id: "onboarding")
    }
}
