import AppKit
import SwiftUI

/// 组合录制控件（2026-10-01 裁决 #12：快捷键全量自定义）：点「录制/修改」后捕获下一次
/// 按键组合。两种形态：
/// - `.trigger` 录音触发键：额外允许裸修饰键（flagsChanged 捕获，如右 ⌘/右 ⌥ 单键），
///   onRecord 由调用方写 AppSettings.recordingHotkeyCombo；
/// - `.style` 风格快捷键：要求普通主键 + ⌘⌥⌃（规则校验见 HotkeyCombo），onRecord 由
///   调用方写库（同组合互斥在 StyleRepository 层）。
///
/// 捕获期间引擎全直通（HotkeyEngine.setCaptureActive）——重录已绑定的组合不会被引擎
/// 自己吞掉/触发听写；捕获走 App 内本地 NSEvent 监听（App 前台时有效，符合设置页场景）。
/// 规则/语义校验失败显示行内提示并继续监听；纯 Esc 取消捕获。
struct HotkeyRecorder: View {
    enum Kind { case trigger, style }

    let kind: Kind
    /// 当前组合（nil = 未绑定；显示于键帽）。
    let current: HotkeyCombo?
    /// 录制成功回调（规则校验 + onValidate 均通过后触发一次）。
    let onRecord: (HotkeyCombo) -> Void
    /// 附加语义校验（与录音触发键/其他风格冲突等）：返回行内提示文案则拒绝本次录制。
    var onValidate: ((HotkeyCombo) -> String?)?
    /// 显示「解除」按钮（风格形态；nil = 隐藏）。
    var onUnbind: (() -> Void)?
    /// 出现即自动进入捕获态（`--hotkey-capture` 截图/走查用；DEBUG 门控在调用方）。
    var autoCapture = false

    @Environment(AppEnvironment.self) private var environment
    @State private var capturing = false
    @State private var invalidHint: String?
    @State private var eventMonitor: Any?
    /// 触发键裸修饰键追踪（bug00017：按下不动、松开才成立，组合主键得以到达）。
    @State private var bareTracker = BareKeyCaptureTracker()
    /// 按住待定中的裸修饰键显示名（键帽预览，松开/组合到达即清除）。
    @State private var barePreview: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if capturing {
                captureControl
            } else {
                idleControl
            }
            if let invalidHint {
                Text(invalidHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if autoCapture { beginCapture() } }
        .onDisappear { endCapture(recorded: nil) }
    }

    // MARK: - 形态

    /// TASK-088 用户裁决：两端锚定——键帽/未绑定灰字贴容器左缘、修改/解除按钮钉
    /// 右缘（Spacer 填充）。置于 valueColumn(230) 等定宽容器时各行按钮右缘对齐
    /// 同一竖线（键帽长短/有无解除不再影响按钮落点）；无定宽容器（风格编辑页）
    /// 时 Spacer 无空间可占，保持内容自适应紧凑形态，零回归。
    /// TASK-089 用户裁决：风格行去掉「修改」（换组合 = 解除 → 录制两步）——
    /// 录制/修改按钮仅在 `current == nil`（未绑定，显「录制」）或 `onUnbind == nil`
    /// （录音触发键行：无解除路径，此按钮是换键唯一入口，必须保留，绑定态显「修改」）
    /// 时显示；已绑定风格行只显「解除」。
    private var idleControl: some View {
        HStack(spacing: 8) {
            if let current {
                KbdKey(text: current.displayText, size: 13)
            } else {
                Text("settings.hotkey.unbind")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            if current == nil || onUnbind == nil {
                Button(current == nil ? "settings.hotkey.recorder.record" : "settings.hotkey.recorder.change") {
                    beginCapture()
                }
                .buttonStyle(.themeGhost)
                .controlSize(.small)
            }
            if current != nil, let onUnbind {
                Button("settings.hotkey.recorder.unbind", action: onUnbind)
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        }
    }

    /// 捕获态同款两端锚定（提示贴左、取消钉右）——录制中按钮不跳位。
    private var captureControl: some View {
        HStack(spacing: 8) {
            // 待定预览：按住单个修饰键时显示键帽（按下阶段不结束捕获——组合主键还在路上）
            if let barePreview {
                KbdKey(text: barePreview, size: 13)
            }
            Text(kind == .trigger
                 ? "settings.hotkey.recorder.listening.trigger"
                 : "settings.hotkey.recorder.listening")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(FieldBackground())
            Spacer(minLength: 12)
            Button("settings.hotkey.recorder.cancel") { endCapture(recorded: nil) }
                .buttonStyle(.themeGhost)
                .controlSize(.small)
        }
    }

    // MARK: - 捕获生命周期

    private func beginCapture() {
        guard !capturing else { return }
        capturing = true
        invalidHint = nil
        bareTracker.reset()
        barePreview = nil
        environment.hotkeyEngine.setCaptureActive(true)
        // struct 视图副本捕获：@State 为外置引用存储，闭包内写入有效（项目既有模式）
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // 捕获中的 keyDown 本地吞掉（组合键不再误触本 App 的菜单/按钮）；
            // flagsChanged 直通（修饰键状态对系统必须透明）
            if event.type == .keyDown, !event.isARepeat {
                handleCaptureEvent(event)
                return nil
            }
            handleCaptureEvent(event)
            return event
        }
    }

    private func endCapture(recorded: HotkeyCombo?) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if capturing {
            environment.hotkeyEngine.setCaptureActive(false)
        }
        capturing = false
        bareTracker.reset()
        barePreview = nil
        if let recorded {
            onRecord(recorded)
        }
    }

    // MARK: - 捕获事件（本地监听回调，主线程）

    /// NSEvent 修饰位 → CGEventFlags（宽度转换；HotkeyCombo 保持纯 CoreGraphics 依赖）。
    private static func cgFlags(_ event: NSEvent) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        let modifiers = HotkeyCombo.Modifier.set(from: Self.cgFlags(event))
        switch event.type {
        case .keyDown where !event.isARepeat:
            // 组合主键到达：裸修饰待定作废（bug00017——按下阶段不抢跑，此处与风格形态
            // 完全共用同一路径）
            bareTracker.reset()
            barePreview = nil
            let keyCode = Int(event.keyCode)
            // 纯 Esc = 取消捕获（与其他修饰组合的 Esc 不算，继续等待）
            if keyCode == HotkeyCombo.escapeKeyCode, modifiers.isEmpty {
                endCapture(recorded: nil)
                return
            }
            let combo = HotkeyCombo(modifiers: modifiers, keyCode: keyCode)
            accept(combo)
        case .flagsChanged where kind == .trigger:
            // 裸修饰键 = 「单独按下 → 松开」全程无其他按键（轻点录入）；
            // 按下瞬间只进入待定（键帽预览），不结束捕获——组合前置修饰让路。
            switch bareTracker.feedFlagsChanged(
                keyCode: Int(event.keyCode), flags: Self.cgFlags(event)) {
            case .accept(let bare):
                barePreview = nil
                accept(HotkeyCombo(bare: bare))
            case .pending(let bare):
                barePreview = bare.displayText
            case .idle:
                barePreview = nil
            }
        default:
            break
        }
    }

    private func accept(_ combo: HotkeyCombo) {
        let failure = kind == .trigger ? combo.triggerRuleFailure : combo.styleRuleFailure
        if let failure {
            invalidHint = hintText(failure)
            return
        }
        if let conflict = onValidate?(combo) {
            invalidHint = conflict
            return
        }
        invalidHint = nil
        endCapture(recorded: combo)
    }

    private func hintText(_ failure: HotkeyCombo.RuleFailure) -> String {
        switch failure {
        case .needsCommandLikeModifier:
            return String(localized: "settings.hotkey.recorder.need.modifier", bundle: AppResources.bundle)
        case .reservedKey:
            return String(localized: "settings.hotkey.recorder.reserved", bundle: AppResources.bundle)
        case .bareModifierNotAllowed:
            return String(localized: "settings.hotkey.recorder.bare", bundle: AppResources.bundle)
        }
    }
}

// MARK: - 裸修饰键捕获状态机（纯逻辑，单测覆盖）

/// 触发键裸修饰键的成立判定（bug00017）：按下瞬间**不做任何接受**——用户可能正要按
/// 组合的主键（⌘+P 的 ⌘ 先到，与风格形态「按下阶段专心等 keyDown」行为一致）；
/// 「单独按下 → 松开」全程无 keyDown（调用方 reset）/其他修饰混入才接受为裸修饰键。
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

    /// flagsChanged 喂入（flags = 事件后的修饰状态；NSEvent.flagsChanged 语义）。
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

    /// keyDown（组合主键）到达或捕获结束——作废待定（组合路径对裸修饰状态零感知）。
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
