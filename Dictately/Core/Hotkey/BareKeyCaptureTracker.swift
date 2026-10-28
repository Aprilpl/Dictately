import CoreGraphics

// MARK: - 裸修饰键轻点状态机（纯逻辑，单测覆盖；引擎与录制控件共用）

/// 裸修饰键的「轻点」成立判定：按下瞬间**不做任何接受**——用户可能正要按
/// 组合的主键（⌘+P 的 ⌘ 先到，与风格形态「按下阶段专心等 keyDown」行为一致）；
/// 「单独按下 → 松开」全程无 keyDown（调用方 reset）/其他修饰混入才接受为
/// 一次轻点。TASK-154 起双用途：
/// - 录制控件（HotkeyRecorder）：裸修饰键录入（bug00017 起源）；
/// - 引擎（HotkeyEngine）：风格裸修饰键触发判定——⌘C/⌘V 等组合用法期间必有
///   keyDown 到达或修饰混入，轻点不成立，绝不误触风格听写。
struct BareKeyCaptureTracker: Equatable {
    enum Decision: Equatable {
        /// 单独按下又松开（轻点）→ 裸修饰键成立。
        case accept(HotkeyCombo.BareModifier)
        /// 单独按住中，等待后续（keyDown 组合主键 / 松开 / 混入其他修饰）。
        case pending(HotkeyCombo.BareModifier)
        /// 无待定（无修饰按住 / 多修饰混入后作废）。
        case idle
    }

    /// 单独按住中的裸修饰键。
    private(set) var heldBare: HotkeyCombo.BareModifier?

    /// flagsChanged 喂入（flags = 事件后的修饰状态；flagsChanged 事件语义）。
    mutating func feedFlagsChanged(keyCode: Int, flags: CGEventFlags) -> Decision {
        let modifiers = HotkeyCombo.Modifier.set(from: flags)
        // 非裸修饰键家族（shift 等）的变化：不影响待定，只回报当前状态
        guard let changed = HotkeyCombo.BareModifier.first(forKeyCode: keyCode) else {
            return heldBare.map { .pending($0) } ?? .idle
        }
        let changedFamily = Self.family(of: changed)

        // 该键松开：待定的正是它（同家族）且修饰集已清空 → 轻点成立
        if !changed.isDown(flags: flags) {
            defer { heldBare = nil }
            if let held = heldBare, Self.family(of: held) == changedFamily, modifiers.isEmpty {
                return .accept(held)
            }
            return .idle
        }
        // 该键按下：修饰集恰为该家族一位（单独）才进入待定；混入其他修饰即作废
        if modifiers == [changedFamily] {
            heldBare = changed
            return .pending(changed)
        }
        heldBare = nil
        return .idle
    }

    /// keyDown（组合主键）到达或判定作废——清空待定（组合路径对裸修饰状态零感知）。
    mutating func reset() {
        heldBare = nil
    }

    /// 裸修饰键 → 家族修饰位（rcommand/lcommand → .command 等）。
    private static func family(of bare: HotkeyCombo.BareModifier) -> HotkeyCombo.Modifier {
        switch bare {
        case .rightCommand, .leftCommand: return .command
        case .rightOption, .leftOption: return .option
        case .rightControl, .leftControl: return .control
        }
    }
}
