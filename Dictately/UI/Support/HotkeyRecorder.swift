import AppKit
import SwiftUI

/// 组合录制控件（2026-10-01 裁决 #12：快捷键全量自定义）：点「录制/修改」后捕获下一次
/// 按键组合。两种形态：
/// - `.trigger` 录音触发键：允许裸修饰键（flagsChanged 捕获，如右 ⌘/右 ⌥ 单键），
///   onRecord 由调用方写 AppSettings.recordingHotkeyCombo；
///   TASK-153 方案 C：传 `triggerMenu` 时「录制/修改」钮改为弹出 TriggerKeyMenu
///   （录制新组合 / 绑定风格快捷键）；`boundDisplay` 驱动绑定态键帽+风格 chip；
///   `onCaptureSuggestion` 把「按到风格组合」从冲突报错升级为绑定引导行；
/// - `.style` 风格快捷键：普通主键 + ⌘⌥⌃，或裸修饰键（TASK-154 放开：轻点触发，
///   不与触发键/其他风格冲突），onRecord 由调用方写库（同组合互斥在
///   StyleRepository 层）。
///
/// 捕获期间引擎全直通（HotkeyEngine.setCaptureActive）——重录已绑定的组合不会被引擎
/// 自己吞掉/触发听写；捕获走 App 内本地 NSEvent 监听（App 前台时有效，符合设置页场景）。
/// 规则/语义校验失败显示行内提示并继续监听；纯 Esc 取消捕获。
struct HotkeyRecorder: View {
    enum Kind { case trigger, style }

    /// 捕获到风格组合时的绑定引导（TASK-153，替代旧冲突报错）：text 行内文案 +
    /// actionTitle 按钮标题 + action 绑定动作（执行前控件先退出捕获态）。
    struct CaptureSuggestion {
        let text: String
        let actionTitle: String
        let action: () -> Void
    }

    let kind: Kind
    /// 当前组合（nil = 未绑定；显示于键帽）。
    let current: HotkeyCombo?
    /// 录制成功回调（规则校验 + onValidate 均通过后触发一次）。
    let onRecord: (HotkeyCombo) -> Void
    /// 附加语义校验（与录音触发键/其他风格冲突等）：返回行内提示文案则拒绝本次录制。
    var onValidate: ((HotkeyCombo) -> String?)?
    /// 显示「解除」按钮（风格形态；nil = 隐藏）。
    var onUnbind: (() -> Void)?
    /// 触发键形态专属（TASK-153）：非 nil 时「录制/修改」钮弹出 TriggerKeyMenu。
    var triggerMenu: TriggerKeyMenuModel?
    /// 菜单风格行回调（页面写绑定 + 刷新引擎抑制态）。
    var onPickStyle: ((Int64) -> Void)?
    /// 绑定态展示（键帽跟随风格当前组合 + 风格 chip）；非 nil 时替代 current 键帽。
    var boundDisplay: (combo: HotkeyCombo, styleName: String)?
    /// 捕获到风格组合 → 返回引导则显示绑定行（捕获继续，不落 onRecord）。
    var onCaptureSuggestion: ((HotkeyCombo) -> CaptureSuggestion?)?
    /// 出现即自动进入捕获态（`--hotkey-capture` 截图/走查用；DEBUG 门控在调用方）。
    var autoCapture = false
    /// 出现即自动开菜单（`--hotkey-trigger-menu` 截图/走查用；DEBUG 门控在调用方）。
    var autoOpenMenu = false

    @Environment(AppEnvironment.self) private var environment
    @State private var capturing = false
    @State private var invalidHint: String?
    /// 绑定引导行在场内容（仅捕获态渲染；Esc/取消/录成即清）。
    @State private var suggestion: CaptureSuggestion?
    @State private var menuPresented = false
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
            if capturing, let suggestion {
                suggestionRow(suggestion)
            }
            if let invalidHint {
                Text(invalidHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if autoCapture { beginCapture() }
            if autoOpenMenu, triggerMenu != nil {
                // 裸跑冷启动窗口上屏可晚于首帧（§70/§77 多实例/重页）：1–6s 幂等置位
                // 重试（已弹出时 updateNSView 无副作用；用户手动收起会被再开——仅调试参数，
                // 6s 后停止）
                for delay in stride(from: 1.0, through: 6.0, by: 1.0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if !capturing { menuPresented = true }
                    }
                }
            }
        }
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
            if let boundDisplay {
                // 绑定态（TASK-153）：键帽跟随风格当前组合 + 风格 chip（自定义组合此时停用）
                KbdKey(text: boundDisplay.combo.displayText, size: 13)
                Chip(
                    text: boundDisplay.styleName,
                    tone: .brand,
                    font: .system(size: 11.5, weight: .semibold),
                    paddingH: 8, paddingV: 2)
            } else if let current {
                KbdKey(text: current.displayText, size: 13)
            } else {
                Text("settings.hotkey.unbind")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            if current == nil || onUnbind == nil {
                entryButton
            }
            if current != nil, let onUnbind {
                Button("settings.hotkey.recorder.unbind", action: onUnbind)
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        }
    }

    /// 「录制/修改」入口：triggerMenu 在场（触发键形态）→ MenuPopoverHost 锚定菜单
    /// （方案 C）；否则直接进捕获（风格形态 / 菜单未接线的触发键，行为同旧版）。
    @ViewBuilder private var entryButton: some View {
        if kind == .trigger, let triggerMenu {
            MenuPopoverHost(
                isPresented: $menuPresented,
                menu: TriggerKeyMenu(
                    model: triggerMenu,
                    onRecordNew: {
                        menuPresented = false
                        beginCapture()
                    },
                    onPickStyle: { styleId in
                        menuPresented = false
                        onPickStyle?(styleId)
                    })
            ) {
                Button(current == nil ? "settings.hotkey.recorder.record"
                                      : "settings.hotkey.recorder.change") {
                    menuPresented.toggle()
                }
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        } else {
            Button(current == nil ? "settings.hotkey.recorder.record"
                                  : "settings.hotkey.recorder.change") {
                beginCapture()
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)
        }
    }

    /// 绑定引导行（TASK-153 冲突升级）：蓝 tint 底 + 引导文案 + 「绑定为风格触发」钮；
    /// 点按钮 = 先退出捕获（收事件监听/解除引擎直通）再执行绑定动作。
    private func suggestionRow(_ suggestion: CaptureSuggestion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(suggestion.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(suggestion.actionTitle) {
                let action = suggestion.action
                endCapture(recorded: nil)
                action()
            }
            .buttonStyle(.themePrimary)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.blueTintBg))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.blueTintBorder, lineWidth: 0.5))
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
        suggestion = nil
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
        suggestion = nil
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
        case .flagsChanged:
            // 裸修饰键 = 「单独按下 → 松开」全程无其他按键（轻点录入；TASK-154 起
            // 触发键/风格两形态均可录入裸修饰键）；
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
            suggestion = nil
            return
        }
        // 捕获到风格组合（触发键形态）：绑定引导替代旧冲突报错（TASK-153）——
        // 引导行在场、捕获继续（用户可改按其他组合或点绑定）
        if kind == .trigger, let proposed = onCaptureSuggestion?(combo) {
            invalidHint = nil
            suggestion = proposed
            return
        }
        if let conflict = onValidate?(combo) {
            invalidHint = conflict
            suggestion = nil
            return
        }
        invalidHint = nil
        suggestion = nil
        endCapture(recorded: combo)
    }

    private func hintText(_ failure: HotkeyCombo.RuleFailure) -> String {
        switch failure {
        case .needsCommandLikeModifier:
            return String(localized: "settings.hotkey.recorder.need.modifier", bundle: AppResources.bundle)
        case .reservedKey:
            return String(localized: "settings.hotkey.recorder.reserved", bundle: AppResources.bundle)
        }
    }
}

// MARK: - 裸修饰键捕获状态机（纯逻辑，单测覆盖）

// BareKeyCaptureTracker 已迁 Core/Hotkey/（TASK-154：引擎风格裸修饰轻点判定同源共用）。

