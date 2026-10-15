import AppKit
import SwiftUI

// MARK: - 纯逻辑状态机（可单测）

/// API Key 三态编辑状态机（2026-10-03 HTML 原型定稿 → Swift 落地，同日三轮追裁；零 UI 依赖）。
/// ① display：chip 展示态；② editing(entry)：编辑态，entry = 进入时的掩码/空串基准；
/// ③ confirming(entry, pending)：离开输入框即进入（无论是否修改），等用户在气泡里裁决。
/// 值的提交**只经 confirmPending**（二次确认）——「只有气泡确认才可以修改 Key」是本状态机不变量。
/// 转移产出 `Action`（commit(value) / none）由 View 层执行存储——组件自身不碰 SecretStore。
/// 掩码守卫：值含 `•`（用户只删了部分掩码圆点）一律视为未修改，绝不落盘成字面掩码。
struct APIKeyEdit: Equatable {
    enum State: Equatable {
        case display
        case editing(entry: String)
        case confirming(entry: String, pending: String)
    }

    /// 编辑态首帧掩码（原型定稿：字面掩码预填全选，直接输入即整体覆盖；非 SecureField——
    /// 展示态是 chip，真实 Key 从不回填明文，掩码串只存在于编辑首帧）。
    static let mask = "sk-••••••••••"

    private(set) var state: State = .display

    var isEditing: Bool {
        if case .editing = state { return true }
        return false
    }

    var isConfirming: Bool {
        if case .confirming = state { return true }
        return false
    }

    /// 展示态 → 编辑态。已配置预填掩码，未配置为空（placeholder 提示 sk-…）。
    mutating func beginEdit(hasKey: Bool) {
        state = .editing(entry: hasKey ? Self.mask : "")
    }

    /// 离开输入框（失焦 / Enter，2026-10-03 三轮追裁）：只要进过编辑态，**无条件**进确认态
    /// 等气泡裁决——不再区分是否修改（「只要点击了输入框，离开时就弹确认框」）。
    mutating func leave(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .editing(let entry) = state else { return }
        state = .confirming(entry: entry, pending: trimmed)
    }

    /// 气泡「保存」：pending 相对 entry 有真修改才产出 commit（空串 = 删除 Key 的合法 commit）；
    /// 未修改 / 掩码圆点残留 = `.none` 原值维持。无论是否提交都回展示态——chip 状态变化即反馈。
    mutating func confirmPending() -> Action {
        guard case .confirming(let entry, let pending) = state else { return .none }
        state = .display
        return Self.isRealChange(pending, from: entry) ? .commit(pending) : .none
    }

    /// 气泡「放弃」/ 外点收起（popoverDidClose）：回展示态维持原 Key。
    /// 对 display 调用是合法空操作——提交后的随行收起无需调用方区分。
    mutating func discardPending() {
        state = .display
    }

    /// 掩码守卫：与 entry 不同且不含掩码圆点才算真修改。
    private static func isRealChange(_ trimmed: String, from entry: String) -> Bool {
        trimmed != entry && !trimmed.contains(Self.maskBullet)
    }

    private static let maskBullet: Character = "•"

    struct Action: Equatable {
        let value: String?
        static let none = Action(value: nil)
        static func commit(_ value: String) -> Action { Action(value: value) }
    }
}

// MARK: - 视图

/// API Key 三态交互字段（AI 服务二级页与听写模型页共享；接缝见回调）。
/// ① 展示态：原位一枚状态 chip（✓ 已配置绿 / 未配置橙），chip 即点击入口（hover 聚焦圈）；
/// ② 编辑态：点击 chip → NSTextField（掩码预填全选，直接输入整体覆盖），**无行内保存按钮**
///    （2026-10-03 三轮追裁移除——提交只经气泡二次确认）；
/// ③ 离开（失焦 / Enter / Esc / 鼠标点输入框外任意处——含空白区）：**一律弹**
///    NSPopover(transient)「是否保存修改？」〔保存/放弃〕——未修改也弹，Esc 不作放弃捷径；
///    只有气泡「保存」（二次确认）才可能修改 Key（放弃 / 外点收起 = 还原原值）。
/// ④ 裁决收口弹 Toast（屏幕中央、窗口级浮动面板 1.5s、点击穿透）：保存且实际提交 = 「API Key已更改」，
///    其余一切收口（放弃/外点收起/未裁决关闭，以及保存被守卫拦截的未修改/掩码残留）= 「API Key未更改」
///    （2026-10-03 追裁四；屏幕中央与文案均系同日追裁，原「已保存/未保存」）。
/// 接缝：`isConfigured` 由父层镜像驱动（bug00013 规则），`onCommit` 里父层写 Keychain 并刷新镜像
/// （沿 saveAPIKey 既有语义：SecretAccount.*Account(for:) 解析账户、CachingSecretStore 写穿透）。
struct APIKeyField: View {
    /// Debug 自动化起始态（--key-edit / --key-confirm / --key-toast-saved / --key-toast-unsaved
    /// 截图走查用；沿 --hotkey-capture 先例）。
    enum DebugStart { case none, editing, confirming, toastSaved, toastUnsaved }

    var isConfigured: Bool
    var debugStart: DebugStart = .none
    /// 「获取 API Key」官网外链（TASK-110 追裁 2026-10-06）：仅**未配置展示态**渲染在
    /// chip 右侧同行——已配置 / 编辑态 / 确认态不显示（三态切换时显隐由本组件内部天然
    /// 保证，父视图零状态外泄；custom 供应商传 nil）。点击 NSWorkspace.open 默认浏览器。
    var getKeyPageURL: URL? = nil
    var onCommit: (String) -> Void

    @State private var edit = APIKeyEdit()
    @State private var fieldValue = ""
    @State private var fieldFocused = false
    @State private var chipHovering = false
    @State private var confirmPopover: NSPopover?
    @State private var popoverBox = PopoverBox()
    /// NSView 锚点（气泡 show(relativeTo:) / Toast 定位用）；confirming 态字段保持可见即锚点稳定。
    @State private var fieldBox = ViewBox()
    /// 编辑态鼠标外点监视器（点输入框外任意处 = 离开；观察不吞，事件照常到达原目标）。
    @State private var outsideClickMonitor: Any?
    /// 当前 Toast 浮动面板（屏幕中央；单实例，新 toast 顶掉旧的）与自灭任务。
    @State private var toastPanel: NSPanel?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if edit.isEditing || edit.isConfirming {
                keyField
            } else {
                chipButton
                // 追裁（TASK-110）：链接只在未配置展示态可见——本分支即展示态，
                // isConfigured 判定未配置；编辑/确认态走 keyField 分支自然消失
                if !isConfigured, let getKeyPageURL {
                    ExternalLink(title: "models.key.get", url: getKeyPageURL)
                        .padding(.leading, 4)
                }
            }
        }
        .onAppear { applyDebugStartIfNeeded() }
        .onChange(of: debugStart) { _, _ in applyDebugStartIfNeeded() }
        .onDisappear {
            removeOutsideClickMonitor()
            confirmPopover?.close()
        }
    }

    /// Debug 起始态：editing 直入编辑；confirming / toast* 再以演示修改值触发失焦确认气泡，
    /// toast* 随即自动走保存/放弃收口弹出 Toast（截图走查用——**须延迟执行**：onChange 触发时
    /// 字段可能尚未挂窗，气泡有自己的 0.2s 重试，Toast 的 field guard 等不起，直接同步跑会静默落空）。
    /// 时机由父视图掌握（load 完成后才置 debugStart，onChange 触发时 isConfigured 镜像已就绪）。
    private func applyDebugStartIfNeeded() {
        guard debugStart != .none, !edit.isEditing, !edit.isConfirming else { return }
        startEditing()
        if debugStart != .editing {
            fieldValue = "sk-demo-edit-123"
            edit.leave(fieldValue)
            if edit.isConfirming { showConfirmPopover() }
            if debugStart == .toastSaved || debugStart == .toastUnsaved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                    guard edit.isConfirming else { return }
                    if debugStart == .toastSaved {
                        run(edit.confirmPending())
                        showToast(.saved)
                    } else {
                        edit.discardPending()
                        showToast(.unsaved)
                    }
                    confirmPopover?.close()
                }
            }
        }
    }

    // MARK: 展示态 · chip

    private var chipButton: some View {
        Button {
            startEditing()
        } label: {
            Chip(
                text: String(localized: isConfigured ? "models.key.configured" : "models.key.notconfigured"),
                tone: isConfigured ? .green : .orange)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chipHovering ? Theme.blueTintBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { chipHovering = $0 }
        .help(Text("settings.key.edit.hint"))
    }

    // MARK: 编辑态 · 字段（样式对齐 GlassField 聚焦态）

    private var keyField: some View {
        KeyTextField(
            text: $fieldValue,
            editable: edit.isEditing, // confirming 态禁编辑：裁决只经气泡
            onFocusChange: { fieldFocused = $0 },
            onEndEditing: endEditing,
            onLeave: leaveFromField,
            onViewReady: { fieldBox.view = $0 })
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: 150) // 总宽 150（含内距，GlassField 同序）；行内保存按钮已随三轮追裁移除
            .background(FieldBackground())
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        fieldFocused ? Theme.blueTintBorder : Theme.line,
                        lineWidth: 1))
    }

    // MARK: - 转移执行

    /// 展示态 → 编辑态（chip 点击 / Debug 起始态共用）。
    private func startEditing() {
        edit.beginEdit(hasKey: isConfigured)
        fieldValue = isConfigured ? APIKeyEdit.mask : ""
        installOutsideClickMonitor()
    }

    // MARK: - 编辑态鼠标外点监视

    /// macOS 点窗口空白区/文字标签**不转移 first responder**，blur 通道不会触发——
    /// 补齐「点输入框外任意处 = 离开」：编辑态装本地 NSEvent monitor，观察不吞
    /// （点击照常落到原目标；若目标可聚焦，随行 blur 由状态机 editing 守卫吞掉，不双弹）。
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard edit.isEditing, let field = fieldBox.view, field.window != nil,
                  event.window === field.window else { return event }
            let point = field.convert(event.locationInWindow, from: nil)
            if !field.bounds.contains(point) {
                enterConfirming(fieldValue)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// 离开输入框 → 确认气泡（失焦 / Enter / Esc / 鼠标外点 / Debug 共用）：
    /// 无论是否修改都弹（三轮追裁）。
    private func enterConfirming(_ value: String) {
        removeOutsideClickMonitor()
        edit.leave(value)
        if edit.isConfirming { showConfirmPopover() }
    }

    /// 失焦决策延迟一轮主队列：气泡「保存」提交后 state 已回 display，字段收起引发的随行
    /// blur 在 editing 守卫处跳过——不二次转移（原「保存按钮 blur 竞态」已随按钮移除消失）。
    private func endEditing() {
        let value = fieldValue
        DispatchQueue.main.async {
            guard case .editing = edit.state else { return }
            enterConfirming(value)
        }
    }

    /// Enter / Esc = 与失焦同路进确认气泡，不直接提交——「只有二次确认才可以修改 Key」；
    /// Esc 同样不作放弃捷径（离开必弹框，2026-10-03 追裁）。
    private func leaveFromField() {
        enterConfirming(fieldValue)
    }

    private func run(_ action: APIKeyEdit.Action) {
        if let value = action.value { onCommit(value) }
    }

    // MARK: 确认气泡（NSPopover transient：外点收起=放弃）

    private func showConfirmPopover(attempt: Int = 0) {
        // 锚点未挂窗或首帧 bounds 未布局（zero rect 会把 popover 定位翻转到锚点上方）：
        // 短暂重试，裁决完成（非 confirming）即止
        guard let anchor = fieldBox.view, anchor.window != nil,
              anchor.frame.width > 1, anchor.frame.height > 1 else {
            guard attempt < 25, edit.isConfirming else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                showConfirmPopover(attempt: attempt + 1)
            }
            return
        }
        confirmPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let content = ConfirmKeyChangeView(
            onSave: {
                let action = edit.confirmPending()
                run(action)
                // Toast 跟随实际动作：.none（未修改/掩码残留被守卫拦截）时 Key 未变，
                // 谎报「已更改」会让用户以为换 Key 成功（2026-10-03 实录：残值滞留致七连 401）
                showToast(action.value == nil ? .unsaved : .saved)
                popover.close()
            },
            onDiscard: {
                edit.discardPending()
                showToast(.unsaved)
                popover.close()
            })
        let hosting = NSHostingController(rootView: content)
        popover.contentViewController = hosting
        // 先完成一次布局拿到实际尺寸再 show——零尺寸 show 会让 AppKit 把气泡翻转定位到锚点上方
        hosting.loadViewIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        popoverBox.onClose = { [weak popover] in
            if confirmPopover === popover {
                // 外点收起 / 未裁决关闭（含页面切走）= 「API Key未更改」；
                // 按钮路径关闭时 state 已是 display，此处跳过——不双弹 Toast
                if edit.isConfirming {
                    edit.discardPending()
                    showToast(.unsaved)
                }
                confirmPopover = nil
            }
        }
        popover.delegate = popoverBox
        confirmPopover = popover
        // 实测定稿（macOS 15）：.maxY = 气泡贴锚点下方（.minY 会弹到上方压住上一行）
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: 裁决结果 Toast（屏幕中央浮动面板，1.5s 自灭）

    /// 气泡裁决收口的 Toast：保存且实际提交 = 「API Key已更改」，其余一切收口（放弃 / 外点收起 /
    /// 未裁决关闭 / 保存被守卫拦截）= 「API Key未更改」——反馈必须与 Keychain 实际状态一致。
    /// 屏幕中央 = 无边框 NSPanel（RecordingPanel 先例：nonactivating + floating + 透明底），
    /// 定位到字段所在屏 visibleFrame 中央（避开 Dock/菜单栏，多屏跟随）；ignoresMouseEvents
    /// 全窗点击穿透，漂浮期不挡任何点击。
    private func showToast(_ kind: ToastKind) {
        guard let screen = fieldBox.view?.window?.screen ?? NSScreen.main else { return }
        // 单实例：新 toast 顶掉旧的（任务取消 + 旧面板直接收起）
        toastDismissTask?.cancel()
        toastDismissTask = nil
        if let old = toastPanel {
            old.orderOut(nil)
            toastPanel = nil
        }
        // SwiftUI .padding(16) 给内容自带的小阴影留扩散边距（§14 教训：窗口边界裁投影）——
        // 边距计入 fittingSize，免手动 NSView 边距拼装
        let hosting = NSHostingView(rootView: KeyToastView(kind: kind).padding(16))
        // 坑（CGWindowList+像素扫描实锤）：未挂窗的 NSHostingView 零帧下 fittingSize 失效
        // （返回近零值 → 面板 62×27、内容 frame 全落可视区外＝空面板）——先给临时尺寸
        // 触发一次 SwiftUI 布局再读 fittingSize
        hosting.setFrameSize(NSSize(width: 400, height: 120))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // 内容自带小阴影；透明窗的系统窗影按矩形成形反而难看
        panel.level = .floating
        panel.ignoresMouseEvents = true // 屏幕中央漂浮 1.5s，必须全窗点击穿透
        panel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        toastPanel = panel
        // 透明度动画（RecordingPanel 先例）：0.18s 淡入 → 1.5s 后 0.2s 淡出收起（savedFlash 同节奏）
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        })
        toastDismissTask = Task { [weak panel] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
            // 兜底强收起：完成回调偶发不达时不留孤儿浮动面板
            try? await Task.sleep(nanoseconds: 400_000_000)
            panel.orderOut(nil)
        }
    }
}

/// 气泡内容（NSHostingController 承载，Theme token 照常生效）。
private struct ConfirmKeyChangeView: View {
    var onSave: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("settings.key.confirm")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text1)
            // 三轮追裁终态：行内保存按钮已移除，气泡主按钮（黑底）是唯一提交口——文案维持「保存」
            //（本轮曾改「确认」，同日用户改判改回，沿用既有键）
            Button("settings.llm.save") { onSave() }
                .buttonStyle(.themePrimary)
                .controlSize(.small)
            Button("settings.key.confirm.discard") { onDiscard() }
                .buttonStyle(.themeGhost)
                .controlSize(.small)
        }
        .padding(10)
    }
}

/// popover 关闭回调载体（View 不是 NSObject，delegate 挂这里）。
private final class PopoverBox: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    func popoverDidClose(_ notification: Notification) { onClose?() }
}

/// NSView 弱引用盒（气泡锚点；@State 持有跨刷新稳定）。
private final class ViewBox {
    weak var view: NSView?
}

// MARK: - 裁决结果 Toast

/// Toast 类型：文案键 + 语义色（2026-10-03 追裁：用户要求已更改态明显绿色——
/// ok/warn 语义色偏深、小字号下近黑，改用鲜绿 green / 鲜橙 orange，双主题同值）。
private enum ToastKind {
    case saved
    case unsaved

    var textKey: LocalizedStringKey {
        self == .saved ? "settings.key.toast.saved" : "settings.key.toast.unsaved"
    }

    var tint: Color { self == .saved ? Theme.green : Theme.orange }
}

/// Toast 内容（屏幕中央浮动面板承载，Theme token；鲜绿/鲜橙语义色）。
private struct KeyToastView: View {
    let kind: ToastKind

    var body: some View {
        Text(kind.textKey)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.modalBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

// MARK: - NSTextField 单行封装（PlainTextEditor 同款手法）

/// 单行 Key 编辑框。GlassField 是纯 SwiftUI TextField，没有失焦回调与全选能力，
/// 承载不了「失焦拦截确认」——本封装补齐：
/// - `controlTextDidBeginEditing` → field editor `selectAll`（掩码全选，直接输入即整体覆盖）；
/// - `controlTextDidEndEditing` → blur 通道（失焦决策入口）；
/// - Enter / Esc（insertNewline / cancelOperation）= 与失焦同路进确认气泡
///   （「只有二次确认才可以修改」，不直接提交；Esc 不作放弃捷径）；
/// - 逐字保留：智能替换全关（Key 值不得被改写）；
/// - 自动聚焦：makeNSView 后异步 makeFirstResponder（chip→字段无缝进入编辑）。
private struct KeyTextField: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var onFocusChange: (Bool) -> Void
    var onEndEditing: () -> Void
    var onLeave: () -> Void
    var onViewReady: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.textColor = NSColor(Theme.text1) // 动态色：随浅/深主题
        field.placeholderString = "sk-…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // 逐字保留在 field editor 上关（智能替换属性属 NSTextView；editor 为窗口共享，每次编辑会话都关一遍）
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.parent = self
        onViewReady(field)
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = editable
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyTextField
        init(_ parent: KeyTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                // 逐字保留（Key 值不得被改写）：field editor 为窗口共享，逐会话关闭智能替换
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
            }
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onFocusChange(false)
            parent.onEndEditing()
        }

        /// Enter / Esc = 离开输入框（返回 true 消费按键；走 leaveFromField 与失焦同一套状态机；
        /// Esc 视为离开而非取消——离开必弹确认气泡；字段转 confirming 禁用引发的随行
        /// endEditing 由 editing 守卫吞掉）。
        func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:))
                || commandSelector == #selector(NSControl.cancelOperation(_:)) {
                // 离开前以 field editor 现值同步绑定——didChange 异步竞态/IME 组字场景下
                // @State 快照可能落后，直接固化会截断 Key（落盘残值 = 服务端 401）
                parent.text = textView.string
                parent.onLeave()
                return true
            }
            return false
        }
    }
}
