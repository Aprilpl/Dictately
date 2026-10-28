import AppKit

/// 生命周期与崩溃兜底日志（PRD §2 Repository Structure）。
/// TASK-015 起：持有依赖容器（App body 求值前可用），启动时预创建面板 + 安装热键。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 依赖容器（App body 求值前创建；@NSApplicationDelegateAdaptor 先于首帧初始化）。
    let environment = AppEnvironment()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // CLT/SPM 裸可执行文件默认是 .proactive（无 Dock/菜单栏），提升为常规 App；
        // 从 .app bundle 启动时同样无害。用户关闭「在程序坞中显示」（TASK-076）→
        // accessory 常驻形态（无 Dock 图标/无应用菜单栏，状态栏图标为常驻入口）。
        // willFinishLaunching 阶段设置，Dock 图标不闪现。
        NSApp.setActivationPolicy(environment.settings.showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // 外观三段（跟随系统/浅/深，TASK-038）：启动应用一次 + 观察设置变化即时重应用
        Theme.applyAppearance(environment.settings.appearance)
        observePreferenceChanges()

        // 状态栏常驻入口（TASK-076）：可见性跟「在状态栏显示图标」设置即时联动
        statusItemController.setVisible(environment.settings.showStatusBarIcon)

        // Key 缓存预热（硬约束 #1）：后台读五账户入缓存，设置页/听写零现场 Keychain 访问
        environment.prefetchSecrets()

        // TASK-015 接线：面板预创建常驻（首唤起 <100ms 预算）+ 热键安装。
        // 无辅助功能权限时 start() 返回 false 并发 onPermissionLost（引导页 TASK-021 接）。
        environment.panelController.warmUp()
        _ = environment.hotkeyEngine.start()
        // 权限丢失（系统更新重置等）→ 重启看守，下次勾选回来自愈
        environment.hotkeyEngine.onPermissionLost = { [weak self] in
            self?.startPermissionWatcher()
        }
        startPermissionWatcher()

        // 回前台即重查权限（TASK-121）：用户从系统授权弹框/系统设置回到 App 时，
        // 权限卡 chip 与引导步状态立即刷新；三个查询均只读不弹窗，常驻观察者安全。
        // 看守 timer 在热键 tap 运行后自毁，此处补上跨场景的刷新空窗。
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        startPanelDebugDemoIfRequested()
        // Debug 专用自动化入口须整体门控（Release 编译无 DEBUG 宏，漏包即断发布构建——
        // TASK-148 实证存量断裂：startLocalModelDebugAutomationIfRequested 曾裸调）
        #if DEBUG
        startLocalModelDebugAutomationIfRequested()
        startUpdaterDebugAutomationIfRequested()
        #endif
    }

    #if DEBUG
    /// Debug 自动化（TASK-134 实机验证用；不依赖窗口可见——宿主合成鼠标不投递，
    /// TASK-129 教训，启动链触发最稳）：
    /// - `--local-runtime-install`：自动触发运行时安装（venv + pip，真网络）
    /// - `--local-download <repo-id>`：对目录内模型触发真实下载（走 App 下载器）
    /// - `--local-use <repo-id>`：切「使用中」为该模型（asrMode=local）
    private func startLocalModelDebugAutomationIfRequested() {
        let args = CommandLine.arguments
        var delay: UInt64 = 0
        if args.contains("--local-runtime-install") {
            delay = max(delay, 400)
            Task { try? await Task.sleep(nanoseconds: 400_000_000)
                environment.localRuntime.install() }
        }
        if let index = args.firstIndex(of: "--local-download"),
           index + 1 < args.count,
           let model = LocalModelCatalog.model(id: args[index + 1]) {
            delay = max(delay, 400)
            // 可选第三参指定渠道（--local-download <repoID> [modelScope|huggingFace]）；
            // 缺省 = 设置当前默认渠道（TASK-144）
            let channel = args.count > index + 2
                ? (AppSettings.DownloadChannel(rawValue: args[index + 2]) ?? .modelScope)
                : environment.settings.localDownloadChannel
            let manager = environment.localModels
            Task { try? await Task.sleep(nanoseconds: 400_000_000)
                manager.startDownload(model, channel: channel) }
        }
        if let index = args.firstIndex(of: "--local-use"),
           index + 1 < args.count,
           LocalModelCatalog.model(id: args[index + 1]) != nil {
            let repoID = args[index + 1]
            let settings = environment.settings
            Task { @MainActor in
                settings.activeLocalModel = repoID
                settings.asrMode = .local
            }
        }
        if delay > 0 {
            AppLog.pipeline.notice("local model debug automation armed (runtime/download/use)")
        }
    }

    /// `--check-updates`：0.6s 后触发 Sparkle 检查更新（TASK-148 本地回环联调——
    /// agent 无辅助功能权限、合成点击无效，走启动链最稳）。默认标准更新窗（同按钮
    /// 路径，截图核验用）；伴 `DICTATELY_SILENT_UPDATE=1` 改静默后台检查 + 自动
    /// 下载安装重启（全链路自动化验证，无人工点击；该开关持久化到 defaults，
    /// 测试后须 `defaults delete com.dictately.Dictately SUEnableAutomaticChecks SUAutomaticallyUpdate`）。
    private func startUpdaterDebugAutomationIfRequested() {
        guard CommandLine.arguments.contains("--check-updates") else { return }
        let silent = ProcessInfo.processInfo.environment["DICTATELY_SILENT_UPDATE"] == "1"
        AppLog.pipeline.notice("updater debug automation armed (silent=\(silent))")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if silent { AppUpdater.checkForUpdatesInBackgroundAndInstall() }
            else { AppUpdater.checkForUpdates() }
        }
    }
#endif

    // MARK: - 偏好即时生效（TASK-038 外观 / TASK-076 Dock 与状态栏）

    /// 状态栏常驻入口（TASK-076）；懒创建避免 willFinishLaunching 前触碰状态栏。
    private lazy var statusItemController: StatusItemController = StatusItemController(
        pipeline: environment.pipeline, router: environment.windowRouter)

    /// 观察设置键变化（任何写入路径——设置 UI/@AppStorage/defaults 写入——都触发）。
    private func observePreferenceChanges() {
        UserDefaults.standard.addObserver(self, forKeyPath: "appearance", options: [.new], context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: "showInDock", options: [.new], context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: "showStatusBarIcon", options: [.new], context: nil)
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard object is UserDefaults else { return }
        switch keyPath {
        case "appearance":
            let raw = (change?[.newKey] as? String) ?? ""
            Theme.applyAppearance(AppSettings.Appearance(rawValue: raw) ?? .system)
        case "showInDock":
            let show = (change?[.newKey] as? Bool) ?? true
            NSApp.setActivationPolicy(show ? .regular : .accessory)
            // 切回 .regular 后拉前台：accessory 形态点不到 Dock，需把主窗口带回焦点
            if show { NSApp.activate(ignoringOtherApps: true) }
        case "showStatusBarIcon":
            statusItemController.setVisible((change?[.newKey] as? Bool) ?? true)
        default:
            break
        }
    }

    // MARK: - 权限看守（首启授权后热键自愈）

    private var permissionWatcher: Timer?

    /// 每 2s 重查辅助功能权限：已授权但 tap 未运行 → 重装热键（首启时无权限、
    /// 用户在引导/系统设置里勾选后，tap 无需重启 App 即可自愈）。
    /// tap 运行中即停看守；权限再丢时由 onPermissionLost 重启看守。
    private func startPermissionWatcher() {
        permissionWatcher?.invalidate()
        let env = environment
        permissionWatcher = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            env.permissions.refresh()
            guard env.hotkeyEngine.state != .running else {
                timer.invalidate() // 已运行：看守使命完成
                return
            }
            guard env.permissions.accessibility == .granted else { return }
            AppLog.hotkey.notice("accessibility granted, installing hotkey tap")
            _ = env.hotkeyEngine.start()
        }
    }

    /// 回前台重查权限（与看守 timer 互补：tap 运行后看守自毁，本观察者常驻）。
    @objc private func appDidBecomeActive() {
        environment.permissions.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 听写工具常驻：关窗口不退出（热键仍可用）
        false
    }

    // MARK: - 面板调试演示（roadmap TASK-013 Verify：强制显示面板、各状态切换演示）

    /// 环境变量 `DICTATELY_DEBUG_PANEL=1` 启动时循环演示面板全部状态
    /// （recording→transcribing→polishing→failed→隐藏），波形用合成电平。
    /// 手动走查步骤见 docs/dev-notes/phase1-manual-checks.md。
    private func startPanelDebugDemoIfRequested() {
        guard ProcessInfo.processInfo.environment["DICTATELY_DEBUG_PANEL"] == "1" else { return }
        AppLog.pipeline.notice("panel debug demo enabled (DICTATELY_DEBUG_PANEL=1)")

        let model = environment.panelModel
        let panel = environment.panelController
        // 合成电平：0.15–0.9 随机起伏（真实电平来自录音，演示不需要麦克风）
        panel.levelSampler = { Float.random(in: 0.15...0.9) }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            defer { step += 1 }
            switch step % 6 {
            case 0:
                model.reset()
                // 演示带风格徽标：徽标自适应宽度是面板视觉走查项之一（TASK-051）
                model.enterRecording(style: "意图识别", escEnabled: true)
                panel.showPanel()
            case 1: model.enterTranscribing()
            case 2: model.enterPolishing()
            case 3: model.enterFailed(String(localized: "panel.failed.timeout"))
            case 4:
                model.reset()
                panel.hidePanel()
            default:
                break // case 5：留一拍空档后从头循环
            }
            if step > 60 { timer.invalidate() } // 演示 ~2 分钟后自行停止
        }
    }
}
