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
    /// 主窗口场景 id（DictatelyApp 的 `Window(id:)` 与本router 共用单点）。
    /// 跨重启稳定：openWindow 的匹配键，改名即失去复用语义。
    static let mainWindowID = "main"

    /// RootView.onAppear 灌入；测试或极早期调用时为 nil（openMain 只记账不崩溃）。
    var openWindowAction: OpenWindowAction?

    /// openMain(at:) 记账的目标侧栏页；RootView onAppear/onChange 消费后清空。
    private(set) var pendingPage: RootView.Page?

    /// 已存在的主窗口（`Window` 场景会把 NSWindow.identifier 设成场景 id）。
    /// 用它而不是只调 openWindow：SwiftUI 对「已存在但被最小化 / 藏在其它 Space」的
    /// 窗口只会排队，不会还原或换 Space（TASK-171 追修实机复现：点黄灯最小化后，
    /// `open` 与 activateAllWindows 都无法让窗口重新出现）。
    private var existingMainWindow: NSWindow? {
        NSApp?.windows.first { $0.identifier?.rawValue == Self.mainWindowID }
    }

    /// 打开（或前置已存在的）主窗口；page 非 nil 时定位侧栏页。
    /// 幂等性由 `Window` 单窗口场景 + 本方法的「已存在只前置」双保险
    /// （TASK-171，§97：`WindowGroup` 下 openWindow 每次都会新建窗口）。
    func openMain(at page: RootView.Page? = nil) {
        if let page { pendingPage = page }
        surfaceMainWindow()
    }

    /// 把主窗口真正带到用户眼前：最小化先还原、再前置，最后激活并拉回当前 Space。
    /// `NSApp.activate` 只管激活，accessory 形态下不会换 Space；
    /// `NSRunningApplication.activate(.activateAllWindows)` 等价「点 Dock 图标」，
    /// 会把主窗口从其它 Space 拉回（实机验证）。
    func surfaceMainWindow() {
        if let window = existingMainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: Self.mainWindowID)
        }
        // NSApp? 可选链：测试环境无 NSApplication 实例，生产恒非 nil 行为不变
        NSApp?.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    /// 消费定位页请求（返回后清账；无请求返回 nil）。
    func consumePendingPage() -> RootView.Page? {
        defer { pendingPage = nil }
        return pendingPage
    }
}
