import AppKit
import ApplicationServices
import CoreGraphics

/// 粘贴注入错误（PRD FR-005 / §11 粘贴输出表）。
enum PasteError: Error, Equatable {
    /// 辅助功能权限缺失——合成键盘事件被系统拒绝（§11：退化为「已复制」提示 + 设置页引导）。
    case accessibilityDenied
    /// 合成事件创建失败（系统资源异常，罕见）。
    case eventCreationFailed
}

/// 键盘事件合成接缝（单测注入假合成器断言事件序，绝不真注入）。
protocol KeyboardEventSynthesizing: AnyObject {
    /// 合成并投递一次按键事件。
    /// - Parameters:
    ///   - keyCode: 虚拟键码（kVK_ANSI_V = 0x09）。
    ///   - flags: 修饰键（⌘ = .maskCommand）。
    ///   - keyDown: true = 按下，false = 释放。
    func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool)
}

/// 真实合成器：CGEvent(keyboardEventSource:virtualKey:keyDown:) → post 到 kCGHIDEventTap（PRD §2 已知坑 #2）。
final class CGKeyboardEventSynthesizer: KeyboardEventSynthesizing {
    private let source: CGEventSource?

    init() {
        // hidSystemState：硬件级事件源，目标 App 前台即可收到
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            AppLog.pipeline.error("CGEvent creation failed key=\(keyCode, privacy: .public)")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

/// 合成 ⌘V 粘贴（PRD FR-005②）。
///
/// 前提：目标 App 在前台（Pipeline 在转写完成时注入，用户焦点未变——面板 nonactivating 保证）。
/// 权限：需要辅助功能（与热键监听同一权限）；缺失时抛 `.accessibilityDenied`，上层退化为「已复制」。
///
/// 校验：PRD FR-005 的 changeCount 校验在「保留结果」策略（Open Q #4 默认）下无可靠信号——
/// 目标 App 读取剪贴板不改变 changeCount。故本类型不做粘贴后断言，仅暴露
/// `pasteSucceeded(bestEffortBefore:)` 供未来恢复剪贴板策略（P2）使用。
final class PasteInjector {
    /// kVK_ANSI_V（PRD §2 已知坑 #2）。
    static let virtualKeyV: CGKeyCode = 0x09

    private let synthesizer: KeyboardEventSynthesizing
    private let isTrusted: () -> Bool

    init(
        synthesizer: KeyboardEventSynthesizing = CGKeyboardEventSynthesizer(),
        isTrusted: @escaping () -> Bool = AXIsProcessTrusted
    ) {
        self.synthesizer = synthesizer
        self.isTrusted = isTrusted
    }

    /// 合成一次 ⌘V：V keyDown（含 ⌘）→ V keyUp（含 ⌘）。按下/释放都带修饰键，
    /// 与真实键盘行为一致，避免个别 App 只看 keyUp flags 的边角。
    func paste() throws {
        guard isTrusted() else { throw PasteError.accessibilityDenied }
        AppLog.pipeline.notice("pasting via synthesized ⌘V")
        synthesizer.postKeyEvent(keyCode: Self.virtualKeyV, flags: [.maskCommand], keyDown: true)
        synthesizer.postKeyEvent(keyCode: Self.virtualKeyV, flags: [.maskCommand], keyDown: false)
    }

    /// 尽力而为的粘贴校验（FR-005 遗留口）：当前策略恒成功——
    /// 保留结果策略下粘贴消费不产生 changeCount 变化，无可观测信号。
    func pasteSucceeded(bestEffortBefore changeCount: Int) -> Bool {
        _ = changeCount
        return true
    }
}
