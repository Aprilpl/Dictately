import AppKit
import SwiftUI

/// 主窗口几何记忆（TASK-077）：取代「每次打开都按级联规则落屏幕左上」的系统默认。
///
/// 背景（defaults 考古实锤）：SwiftUI 原生会给窗口设 autosave 名并记忆位置，但
/// 键名派生自场景视图的修饰链（`main-AppWindow-1` / `SwiftUI.ModifiedContent<
/// RootView…>-1-AppWindow-1` ……，同一台机器上历史遗留 5 个孤儿键）——代码每次
/// 改动修饰链，键名漂移、旧存档作废，窗口静默回到左上级联位。本组件用**自有的
/// 稳定 defaults 键**接管记忆，跨版本升级不丢：
/// - 恢复：挂窗后延迟一轮主队列再 setFrame（SwiftUI 在场景装配后才应用
///   defaultSize/defaultPosition，同步恢复会被覆盖——实测预置存档 300,600 启动
///   后仍落居中位）；此刻窗口尚未上屏，无跳变。
/// - 保存：didMove / didEndLiveResize / willClose 三通知随时写回（恢复 setFrame
///   触发的 didMove 写回同值，幂等无害）。
/// 无存档（首次启动）不动作——defaultPosition(.center) 已保证居中。
struct WindowFrameRestorer: NSViewRepresentable {
    /// 主窗口几何存档键（UserDefaults.standard，值 NSStringFromRect 格式）。
    /// 键名稳定是本机制的意义所在，勿随版本改动。
    static let frameDefaultsKey = "mainWindowFrame"

    func makeNSView(context: Context) -> NSView { HookView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HookView: NSView {
        /// 每实例只装一次；SwiftUI 重建视图树时旧实例 deinit 自清理。
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            installSaveObservers(window)
            restoreFrame(window)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func restoreFrame(_ window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                guard let raw = UserDefaults.standard.string(forKey: WindowFrameRestorer.frameDefaultsKey),
                      let frame: NSRect = {
                          let rect = NSRectFromString(raw) // 解析失败返回 .zero
                          return rect.width > 0 && rect.height > 0 ? rect : nil
                      }() else {
                    AppLog.app.info("主窗口无几何存档，保持 defaultPosition 居中")
                    return
                }
                // 屏外救回：存档位置完全脱离所有屏幕可见区域（副屏拔掉）时回中；
                // 部分压屏外/跨屏均照常恢复（尊重用户摆放）。
                let visible = NSScreen.screens.map(\.visibleFrame)
                guard WindowFrameVisibility.isOnAnyScreen(frame, screens: visible) else {
                    window.center()
                    AppLog.app.notice("主窗口存档位置已脱离所有屏幕，回中救回")
                    return
                }
                // setFrame 对可缩放窗口自动约束 min/max size（AppKit 行为）。
                window.setFrame(frame, display: false)
                AppLog.app.info("主窗口几何恢复 \(Self.describe(frame))")
            }
        }

        private func installSaveObservers(_ window: NSWindow) {
            guard observers.isEmpty else { return }
            let names = [
                NSWindow.didMoveNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.willCloseNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    UserDefaults.standard.set(
                        NSStringFromRect(window.frame),
                        forKey: WindowFrameRestorer.frameDefaultsKey
                    )
                }
            }
        }

        private static func describe(_ frame: NSRect) -> String {
            "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
        }
    }
}

/// 纯逻辑接缝（可测）：window frame 与屏幕可见区域的可达性判定。
enum WindowFrameVisibility {
    /// frame 与任一屏幕可见区域（避开菜单栏/Dock 的 visibleFrame）有交集即视为可达。
    /// 部分压在屏外/跨屏均算可达——尊重用户摆放；完全脱离所有屏才需要救回。
    static func isOnAnyScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        screens.contains { $0.intersects(frame) }
    }
}
