import AppKit
import SwiftUI

/// 主窗口路由（TASK-076）：`openWindow` 只能在 SwiftUI 环境里调用，而主窗口关闭后
/// RootView 随之销毁——旧 ⌘, 的 NotificationCenter → RootView.onReceive 链路在关窗后
/// 无人接收。RootView.onAppear 把 OpenWindowAction 灌入此处（启动必开主窗，必然先灌到），
/// 之后任何入口（⌘, / 状态栏菜单）都经 router 打开主窗口，关窗后同样可用。
/// 主线程使用（菜单回调 / SwiftUI 生命周期均主线程）。@Observable：RootView 经
/// onChange 观察 pendingPage，主窗口存活时定位页请求也能即时消费。
@Observable
final class WindowRouter {
    /// RootView.onAppear 灌入；测试或极早期调用时为 nil（openMain 只记账不崩溃）。
    var openWindowAction: OpenWindowAction?

    /// openMain(at:) 记账的目标侧栏页；RootView onAppear/onChange 消费后清空。
    private(set) var pendingPage: RootView.Page?

    /// 打开（或前置已存在的）主窗口；page 非 nil 时定位侧栏页。
    /// accessory 形态（Dock 隐藏）下 NSApp.activate 保证窗口拿回键盘焦点。
    func openMain(at page: RootView.Page? = nil) {
        if let page { pendingPage = page }
        openWindowAction?(id: "main")
        // NSApp? 可选链：测试环境无 NSApplication 实例，生产恒非 nil 行为不变
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// 消费定位页请求（返回后清账；无请求返回 nil）。
    func consumePendingPage() -> RootView.Page? {
        defer { pendingPage = nil }
        return pendingPage
    }
}
