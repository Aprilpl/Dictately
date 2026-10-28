import Sparkle

/// Sparkle 2 自动更新（TASK-148）：检查 → 下载 → EdDSA 验签 → 安装并重启。
/// 用户裁决：**仅手动触发**（关于页「检查更新」按钮），启动绝不自动检查——
/// Info.plist `SUEnableAutomaticChecks=false` 与此处属性设置双保险。
/// 控制器懒初始化：用户点按钮才拉起 Sparkle（官方 SwiftUI 模式，主线程使用）。
enum AppUpdater {
    private static let controller: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false
        return controller
    }()

    /// 关于页「检查更新」唯一入口：弹 Sparkle 标准更新窗（自带中文、进度与发布说明）。
    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 本地回环全链路联调专用（`--check-updates` + `DICTATELY_SILENT_UPDATE=1`）：
    /// 后台检查 → 静默下载 → 验签 → 安装并重启，全程无窗口无点击。
    /// 注意两项设置都会持久化到 defaults（SUEnableAutomaticChecks /
    /// SUAutomaticallyUpdate），测试后必须一并
    /// `defaults delete com.dictately.Dictately SUEnableAutomaticChecks SUAutomaticallyUpdate`
    /// 清理，否则正式 App 会自动检查并静默装更新（违反仅手动裁决）。
    /// 自动下载的门槛 allowsAutomaticUpdates 跟随 automaticallyChecksForUpdates
    /// （SPUUpdater.h 明示）——仅手动裁决默认关着，须在此临时打开。
    static func checkForUpdatesInBackgroundAndInstall() {
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
        controller.updater.checkForUpdatesInBackground()
    }
}
