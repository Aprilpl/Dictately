import AppKit

/// 状态栏常驻入口（TASK-076）：菜单栏图标 + 菜单（开始听写/打开主窗口/设置…/退出）。
/// App 关窗不退出（applicationShouldTerminateAfterLastWindowClosed = false），状态栏是
/// 关窗后（以及用户隐藏 Dock 图标后）唯一的常驻可见入口。主线程使用。
final class StatusItemController: NSObject, NSMenuDelegate {
    private let pipeline: DictationPipeline
    private let router: WindowRouter
    private let statusItem: NSStatusItem

    init(pipeline: DictationPipeline, router: WindowRouter) {
        self.pipeline = pipeline
        self.router = router
        // variableLength：按钮随图像自适应宽度（声波图标 26×14pt 横条形，squareLength 会左右裁切）；
        // 模板图像随菜单栏深浅自适应（非硬编码颜色）
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
                ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictately")
            button.image?.isTemplate = true
            button.toolTip = "Dictately"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let dictate = NSMenuItem(
            title: Self.dictationTitle(recording: false), action: #selector(toggleDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)

        let openMain = NSMenuItem(
            title: String(localized: "statusbar.openMain", bundle: AppResources.bundle),
            action: #selector(openMainWindow), keyEquivalent: "")
        openMain.target = self
        menu.addItem(openMain)

        let openSettings = NSMenuItem(
            title: String(localized: "settings.menu.title", bundle: AppResources.bundle),
            action: #selector(openSettingsPage), keyEquivalent: ",")
        openSettings.target = self
        openSettings.keyEquivalentModifierMask = .command
        menu.addItem(openSettings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "statusbar.quit", bundle: AppResources.bundle),
            action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        statusItem.menu = menu
        // 启动诊断锚点（TASK-076 排障：item 创建成功≠渲染，本行用于区分「未创建」与「被系统压制」）
        AppLog.app.notice("status item created (visible=\(self.statusItem.isVisible, privacy: .public))")
    }

    /// 图标可见性（设置「在状态栏显示图标」经 AppDelegate KVO 即时切换）。
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// 菜单栏图标 = 截短版声波纹模板图（2026-10-07 用户裁决，替代 mic.fill，形状与 App 图标同源）。
    /// 2x 资源 52×28 px 按 26×14 pt 显示（14pt 高，Retina 1:1 采样）；模板图只取 alpha 轮廓，
    /// 深浅菜单栏由系统自动黑/白。internal 供测试钉资源契约；资源缺失回退 mic.fill（守卫式）。
    static func menuBarIcon() -> NSImage? {
        let url = AppResources.bundle.url(forResource: "MenuBarIcon-2x", withExtension: "png")
            ?? AppResources.bundle.url(forResource: "MenuBarIcon", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 26, height: 14)
        return image
    }

    // MARK: - NSMenuDelegate（每次打开按当前阶段刷新听写项标题）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.title = Self.dictationTitle(recording: pipeline.phase == .recording)
    }

    private static func dictationTitle(recording: Bool) -> String {
        String(localized: recording ? "statusbar.dictation.stop" : "statusbar.dictation.start", bundle: AppResources.bundle)
    }

    // MARK: - 动作（主线程）

    /// 复用录音热键切换语义（PRD §11）：idle 开始默认听写 / recording 停止 /
    /// cueing·处理中忽略——与全局热键行为一致；菜单发起同样走预滚播音 + 录音静音。
    @objc private func toggleDictation() {
        pipeline.handleHotkeyEvent(.toggleStart)
    }

    @objc private func openMainWindow() {
        router.openMain()
    }

    @objc private func openSettingsPage() {
        router.openMain(at: .general)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
