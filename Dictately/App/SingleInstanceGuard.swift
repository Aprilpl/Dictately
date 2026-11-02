import AppKit

/// 单实例防线（TASK-169，§95 追裁）：同 bundle id 已有实例在跑时，新实例托付后退出。
/// 成因：聚焦/访达把「打开 Dictately」解析到另一路径副本时，LaunchServices 不会激活
/// 运行中的 UIElement（accessory）实例，而是拉起第二进程 → 双开、双 Dock 图标
/// （2026-11-02 实证：build 副本 UIElement 运行中，聚焦命中 /Applications 副本即双开）。
/// 「同一个 App」按 bundle id 判定（不同路径副本同样命中）。
/// 开发旁路（新旧版本并排走查等）：环境变量 DICTATELY_ALLOW_MULTI_INSTANCE=1。
enum SingleInstanceGuard {
    /// 托付通知（跨进程递送通道；接收侧经 WindowRouter 呼出主窗——§18 唯一入口不变，
    /// 与已废止的站内 NotificationCenter 路由模式无关）。
    static let reopenNotificationName = "com.dictately.Dictately.reopenMain"

    /// 决策（纯函数，供测试）：已有同源实例在跑且未旁路 → 托付退出。
    static func shouldDefer(hasOtherRunningInstance: Bool, allowMultiInstance: Bool) -> Bool {
        hasOtherRunningInstance && !allowMultiInstance
    }

    /// 开发旁路：显式允许多实例（并排版本对照等场景）。
    static var allowMultiInstance: Bool {
        ProcessInfo.processInfo.environment["DICTATELY_ALLOW_MULTI_INSTANCE"] == "1"
    }

    /// 现存同 bundle id 其他实例（排除自身；裸跑 .build 二进制无 bundle id 时返回 nil 不设防）。
    static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != selfPID }
    }

    /// 托付动作：通知既有实例呼窗 + 尽力激活（对无监听的旧版实例的次优补救）+ 自行退出。
    /// 须在 willFinishLaunching 最前调用（早于状态栏/热键/Keychain 预热，亡实例零副作用）。
    static func deferToExistingInstance() {
        let other = otherRunningInstance()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(reopenNotificationName), object: nil, deliverImmediately: true)
        AppLog.app.notice(
            "another instance running (pid \(other?.processIdentifier ?? -1, privacy: .public)), deferring and terminating"
        )
        if let other { other.activate(from: .current) }
        NSApp.terminate(nil)
    }
}
