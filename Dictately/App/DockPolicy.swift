import AppKit

/// Dock 图标策略纯函数（TASK-168，§95）：目标 activationPolicy 的唯一派生源。
/// 模式 A 裁决——Dock 图标的存在只由「在程序坞中显示」设置决定，窗口生命周期
/// 不参与判定；系统路径（聚焦/访达再次打开运行中实例）把策略翻回 .regular 后，
/// 由 AppDelegate 的收敛点拉回（见 applyDockActivationPolicy）。
enum DockPolicy {
    /// 设置 → 目标策略：开 = 常规应用（Dock 图标 + 应用菜单栏）；
    /// 关 = accessory 常驻形态（无 Dock 图标，状态栏图标为常驻入口，TASK-076）。
    static func target(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }
}
