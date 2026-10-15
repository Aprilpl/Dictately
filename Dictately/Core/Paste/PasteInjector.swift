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
    /// 以 Unicode 字符串形态投递一次「打字」事件（模拟按键用）。
    /// 调用方保证单次 ≤20 个 UTF-16 码元（CGEvent 单事件上限）。
    func postUnicodeString(_ string: String)
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

    func postUnicodeString(_ string: String) {
        // virtualKey 取 0：目标 App 按 Unicode 字符串载荷消费本事件，键码本身无语义
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            AppLog.pipeline.error("CGEvent creation failed for unicode typing")
            return
        }
        let units = Array(string.utf16)
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        event.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

/// 文本输入方法（TASK-126，用户裁决模仿参考 App）：粘贴按物理键位合成 ⌘ 组合键——
/// 特殊键盘布局下 V 所在物理键不同（如 Dvorak 的 V 在句号键位），盲目发 0x09 无法触发
/// 目标 App 的「粘贴」菜单快捷键。键码值以 CLT SDK Carbon Events.h 为准（§13 铁律）。
enum TextInputMethod: String, CaseIterable {
    /// 粘贴 (⌘+V)——标准 QWERTY，默认。
    case paste = "paste"
    /// 粘贴 (Colemak - ⌘+D)，kVK_ANSI_D = 0x02。
    case pasteColemak = "paste.colemak"
    /// 粘贴 (Dvorak - ⌘+.)，kVK_ANSI_Period = 0x2F（Dvorak 布局 V 在句号键位）。
    case pasteDvorak = "paste.dvorak"
    /// 粘贴 (Optimot - ⌘+/)，kVK_ANSI_Slash = 0x2C。
    case pasteOptimot = "paste.optimot"
    /// 模拟按键：不经 ⌘V，逐段「打」出文字（剪贴板仍写入——TASK-126 用户裁决）。
    case simulateTyping = "simulateTyping"

    /// 粘贴类方法的物理键码；simulateTyping 为 nil。
    var pasteKeyCode: CGKeyCode? {
        switch self {
        case .paste: return 0x09
        case .pasteColemak: return 0x02
        case .pasteDvorak: return 0x2F
        case .pasteOptimot: return 0x2C
        case .simulateTyping: return nil
        }
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

    /// 合成一次粘贴快捷键：目标键 keyDown（含 ⌘）→ keyUp（含 ⌘）。按下/释放都带修饰键，
    /// 与真实键盘行为一致，避免个别 App 只看 keyUp flags 的边角。
    /// keyCode 由文本输入方法决定（默认 ⌘V；特殊布局用户在设置页换对应物理键）。
    func paste(keyCode: CGKeyCode = PasteInjector.virtualKeyV) throws {
        guard isTrusted() else { throw PasteError.accessibilityDenied }
        AppLog.pipeline.notice("pasting via synthesized ⌘V")
        synthesizer.postKeyEvent(keyCode: keyCode, flags: [.maskCommand], keyDown: true)
        synthesizer.postKeyEvent(keyCode: keyCode, flags: [.maskCommand], keyDown: false)
    }

    /// 模拟按键（TASK-126）：以 Unicode 字符串事件逐段「打」出文字，不触碰目标 App 的
    /// 快捷键体系（远程桌面/安全终端等禁用 ⌘V 的场景可用）。UTF-16 按 ≤20 码元分块——
    /// CGEvent 单事件的 unicode 载荷上限，超出部分会被系统截断。
    func typeText(_ text: String) throws {
        guard isTrusted() else { throw PasteError.accessibilityDenied }
        AppLog.pipeline.notice("typing text via unicode events (\(text.utf16.count, privacy: .public) units)")
        let units = Array(text.utf16)
        let chunkLimit = 20
        var start = 0
        while start < units.count {
            let end = min(start + chunkLimit, units.count)
            let chunk = String(decoding: units[start..<end], as: UTF16.self)
            synthesizer.postUnicodeString(chunk)
            start = end
        }
    }

    /// 尽力而为的粘贴校验（FR-005 遗留口）：当前策略恒成功——
    /// 保留结果策略下粘贴消费不产生 changeCount 变化，无可观测信号。
    func pasteSucceeded(bestEffortBefore changeCount: Int) -> Bool {
        _ = changeCount
        return true
    }
}
