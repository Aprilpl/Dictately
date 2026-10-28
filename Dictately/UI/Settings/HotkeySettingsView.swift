import AppKit
import SwiftUI

/// 快捷键设置页（PRD FR-017 / TASK-072 卡片化改版，布局对齐 AI 服务页）：
/// 页头（标题 + 说明）+「录音快捷键」分组卡（热键模式三选 按住/切换/双击 + 触发键录制）
/// +「风格快捷键」分组卡（全局热键模式三选 + 每启用风格一行 HotkeyRecorder）+
/// 「测试你的快捷键」区（TASK-073：真听写输入框——聚焦后直接按快捷键，转写/润色
/// 文本经粘贴注入落回本框；框下 caption 实时显示引擎识别的组合）+
/// 辅助功能权限失效横幅 + 重新授权按钮。表单限宽 620pt、值列 330pt 左对齐块
/// （与 LLMSettingsView 同一裁决）；两卡 = SettingsCard（fillSoft + line + 12 圆角）。
/// 模式均经引擎 provider 每次事件现读——改模式即时生效，无需通知引擎。
struct HotkeySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var styles: [Style] = []
    @State private var permissionBroken = false
    @State private var recognizedText: String?
    /// 组合变更内联提示（互斥自动解除告知，v2-glass exclusivity 同位）。
    @State private var comboNotice: String?
    @State private var pollTimer: Timer?
    @State private var pollObserving = false
    /// 测试听写输入框文本（转写经粘贴注入落回这里，也可直接键入）。
    @State private var testInput = ""

    /// 热键模式本地镜像驱动重绘（AppSettings 非 Observable，直写 defaults 不触发
    /// GlassSegmented 选中块/hint 刷新——沿 GeneralSettingsView.appearance 同款双写）。
    @State private var mode: AppSettings.HotkeyMode = .doubleTap

    /// 风格热键模式本地镜像（TASK-072 全局三选，默认切换；双写规则同上，无例外）。
    @State private var styleMode: AppSettings.HotkeyMode = .toggle

    /// 触发键本地镜像驱动键帽刷新（HotkeyRecorder.current 是构造参数，父视图不重绘
    /// 则键帽停在旧组合；风格区靠 reload() 刷新、触发键无此链路，本地镜像补齐）。
    @State private var triggerCombo = HotkeyCombo(bare: .rightCommand)

    /// 触发键风格绑定本地镜像（TASK-153 方案 C 菜单直选）：nil = 自定义组合生效。
    /// 绑定引用风格 id——键帽/chip 跟随风格当前组合，风格改键自动同步。非 nil 但
    /// boundStyle 为 nil = 绑定不可解析（风格失键/停用/删除）：引擎经 didChange 重算
    /// 已自动恢复自定义组合，行显示回落 + fallback 告知（绑定存储保留，重绑即恢复）。
    @State private var triggerBinding: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if permissionBroken {
                    permissionBanner
                }

                header

                SectionLabel("settings.hotkey.section.record", topPadding: 24)

                SettingsCard {
                    SettingRow("settings.hotkey.mode", hint: modeHintKey) {
                        valueColumn(
                            GlassSegmented(
                                options: modeOptions,
                                selection: modeBinding,
                                small: true,
                                label: { $0.title }
                            )
                            .opacity(boundStyle == nil ? 1 : 0.45)
                            .disabled(boundStyle != nil))
                    }
                    triggerRow
                }

                SectionLabel("settings.hotkey.section.styles", topPadding: 36)

                SettingsCard {
                    SettingRow("settings.hotkey.style.mode", hint: styleModeHintKey, divider: !enabledStyles.isEmpty) {
                        valueColumn(
                            GlassSegmented(
                                options: modeOptions,
                                selection: styleModeBinding,
                                small: true,
                                label: { $0.title }
                            ))
                    }
                    if enabledStyles.isEmpty {
                        Text("settings.hotkey.styles.empty")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text3)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(enabledStyles.enumerated()), id: \.element.id) { index, style in
                            SettingRow(
                                title: style.name,
                                hint: style.description,
                                divider: index != enabledStyles.count - 1
                            ) {
                                valueColumn(
                                    HotkeyRecorder(
                                        kind: .style,
                                        current: style.hotkeyCombo.flatMap(HotkeyCombo.init(storageString:)),
                                        onRecord: { applyCombo($0, to: style) },
                                        onValidate: validateStyleCombo,
                                        onUnbind: { unbind(style) },
                                        autoCapture: index == 0 && debugAutoCapture
                                    ))
                            }
                        }
                    }
                }

                if let comboNotice {
                    Text(comboNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warn)
                        .padding(.vertical, 6)
                }

                testArea
            }
            // TASK-077 用户裁决：内容列弹性 + 居中（同常规设置页）；TASK-080 追裁上限 800。
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            // TASK-082：顶部间距 16→48（×3），底部维持 16
            .padding(.top, 48)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            reload()
            syncSettingsMirrors()
            debugPretendBoundIfNeeded()
            refreshPermissionState()
            startPermissionPolling()
            observeRecognitions()
        }
        .onDisappear {
            pollTimer?.invalidate()
            if pollObserving {
                NotificationCenter.default.removeObserver(
                    self, name: HotkeyEngine.recognizedNotification, object: nil)
                pollObserving = false
            }
        }
    }

    // MARK: - 页头 / 小节标签 / 值列（LLMSettingsView 同款布局语言）

    private var header: some View {
        PageHeader(titleKey: "settings.hotkey.title", descKey: "settings.hotkey.desc")
    }

    // 值列块与小节标签走共享件（PageChrome.swift；§85 收敛）

    // MARK: - 热键模式（录音/风格两卡共用三选；holdOrToggle 为录音键内部残留模式不展示）

    private var modeOptions: [AppSettings.HotkeyMode] {
        [.hold, .toggle, .doubleTap]
    }

    private var modeBinding: Binding<AppSettings.HotkeyMode> {
        Binding(
            get: { mode },
            set: {
                mode = $0
                environment.settings.hotkeyMode = $0 // 引擎 modeProvider 现读 → 即时生效
            }
        )
    }

    private var styleModeBinding: Binding<AppSettings.HotkeyMode> {
        Binding(
            get: { styleMode },
            set: {
                styleMode = $0
                environment.settings.styleHotkeyMode = $0 // 引擎 styleModeProvider 现读 → 即时生效
            }
        )
    }

    /// 录音模式说明随所选档位切换（措辞用「触发键」泛化——键位已可自定义，默认右 ⌘）。
    /// 绑定风格期间模式行置灰（TASK-153）：该键按『风格快捷键』的热键模式工作。
    private var modeHintKey: LocalizedStringKey {
        if boundStyle != nil {
            return "settings.hotkey.trigger.bound.modehint"
        }
        switch mode {
        case .hold: return "settings.hotkey.mode.hint.hold"
        case .toggle: return "settings.hotkey.mode.hint.toggle"
        default: return "settings.hotkey.mode.hint.doubleTap"
        }
    }

    // MARK: - 触发键风格绑定（TASK-153 方案 C 菜单直选）

    /// 绑定当前生效的风格（存在 && enabled && 已绑组合；判定与引擎抑制同源
    /// TriggerKeyMenuModel.isBindable）。nil = 自定义组合（或不可解析回落）。
    private var boundStyle: Style? {
        TriggerKeyMenuModel.resolve(boundId: triggerBinding, styles: styles)
    }

    /// 触发键行：绑定态显示风格键帽 + 风格 chip、hint 换绑定说明；「修改」钮经
    /// TriggerKeyMenu（MenuPopoverHost 锚定）提供「录制新组合 / 绑定风格快捷键」双路。
    private var triggerRow: some View {
        let bound = boundStyle
        let boundCombo = bound?.hotkeyCombo.flatMap(HotkeyCombo.init(storageString:))
        let hint: String
        if let bound, let boundCombo {
            hint = String(
                format: String(localized: "settings.hotkey.trigger.bound.hint", bundle: AppResources.bundle),
                bound.name, boundCombo.displayText)
        } else {
            hint = String(localized: "settings.hotkey.trigger.hint", bundle: AppResources.bundle)
        }
        return SettingRow(
            title: String(localized: "settings.hotkey.trigger", bundle: AppResources.bundle),
            hint: hint,
            divider: false
        ) {
            valueColumn(
                HotkeyRecorder(
                    kind: .trigger,
                    current: triggerCombo,
                    onRecord: recordCustomCombo,
                    triggerMenu: TriggerKeyMenuModel(
                        items: TriggerKeyMenuModel.eligibleStyles(styles),
                        boundStyleId: triggerBinding),
                    onPickStyle: bindTrigger,
                    boundDisplay: bound.map { style in
                        (combo: boundCombo ?? .defaultTrigger, styleName: style.name)
                    },
                    onCaptureSuggestion: captureSuggestion,
                    autoOpenMenu: debugAutoOpenMenu
                ))
        }
    }

    /// 录得新自定义组合（菜单「录制新组合…」路径）：写 settings + 本地镜像，
    /// 并解除风格绑定（绑定与自定义互斥——引擎停用随之解除，右 ⌘ 等自定义键即恢复）。
    private func recordCustomCombo(_ combo: HotkeyCombo) {
        triggerCombo = combo
        environment.settings.recordingHotkeyCombo = combo
        if triggerBinding != nil {
            triggerBinding = nil
            environment.settings.triggerStyleBindingId = nil
            environment.refreshTriggerStyleBinding()
        }
    }

    /// 绑定风格：写 settings + 镜像 → 引擎抑制重算（自定义组合停用、绑定键走风格链路）
    /// → 窗口正中 Toast 反馈。
    private func bindTrigger(to styleId: Int64) {
        guard let style = styles.first(where: { $0.id == styleId }),
              let combo = style.hotkeyCombo.flatMap(HotkeyCombo.init(storageString:)) else { return }
        triggerBinding = styleId
        environment.settings.triggerStyleBindingId = styleId
        environment.refreshTriggerStyleBinding()
        comboNotice = nil
        environment.toast.show(String(
            format: String(localized: "settings.hotkey.trigger.bound.toast", bundle: AppResources.bundle),
            style.name, combo.displayText))
    }

    /// 捕获到风格组合 → 绑定引导（TASK-153 冲突升级，替代旧 validateTrigger 报错拒绝：
    /// 该组合本就归风格所有，作为原声触发键存在归属歧义，引导绑定为正解）。
    private func captureSuggestion(_ combo: HotkeyCombo) -> HotkeyRecorder.CaptureSuggestion? {
        guard let holder = enabledStyles.first(where: { $0.hotkeyCombo == combo.storageString }),
              let holderId = holder.id else {
            return nil
        }
        return HotkeyRecorder.CaptureSuggestion(
            text: String(
                format: String(localized: "settings.hotkey.trigger.suggest", bundle: AppResources.bundle),
                combo.displayText, holder.name),
            actionTitle: String(
                localized: "settings.hotkey.trigger.suggest.action", bundle: AppResources.bundle),
            action: { bindTrigger(to: holderId) })
    }

    /// 风格模式说明（TASK-072：交互语义按风格听写表述）。
    private var styleModeHintKey: LocalizedStringKey {
        switch styleMode {
        case .hold: return "settings.hotkey.style.mode.hint.hold"
        case .toggle: return "settings.hotkey.style.mode.hint.toggle"
        default: return "settings.hotkey.style.mode.hint.doubleTap"
        }
    }

    // MARK: - 风格快捷键（每风格一行录制控件；同组合互斥在 StyleRepository 层）

    private var enabledStyles: [Style] {
        styles.filter(\.enabled)
    }

    /// 风格组合附加校验：不与录音触发键相同。例外（TASK-153）：触发键绑定风格期间
    /// 自定义组合已被引擎停用（不匹配不吞）——允许风格接管该组合，不再误报冲突。
    private func validateStyleCombo(_ combo: HotkeyCombo) -> String? {
        guard boundStyle == nil,
              combo == environment.settings.recordingHotkeyCombo else { return nil }
        return String(localized: "settings.hotkey.recorder.conflict.trigger", bundle: AppResources.bundle)
    }

    /// 录制成功落库：repo 互斥清掉同组合旧持有者 → 内联告知（不阻断）。
    private func applyCombo(_ combo: HotkeyCombo, to style: Style) {
        var changed = style
        changed.hotkeyCombo = combo.storageString
        changed.updatedAt = Date().timeIntervalSince1970
        if let holder = (try? environment.styleRepository.fetchByHotkey(combo.storageString)) ?? nil,
           holder.id != style.id {
            comboNotice = String(
                format: String(localized: "settings.hotkey.combo.taken", bundle: AppResources.bundle),
                combo.displayText, holder.name)
        } else {
            comboNotice = nil
        }
        _ = try? environment.styleRepository.update(changed)
        reload()
    }

    private func unbind(_ style: Style) {
        var changed = style
        changed.hotkeyCombo = nil
        changed.updatedAt = Date().timeIntervalSince1970
        _ = try? environment.styleRepository.update(changed)
        // 级联（TASK-153）：触发键正绑定该风格 → 同步解除绑定并告知
        // （引擎抑制经 didChange 重算自动恢复自定义组合）。
        if triggerBinding != nil, triggerBinding == style.id {
            triggerBinding = nil
            environment.settings.triggerStyleBindingId = nil
            comboNotice = String(
                format: String(localized: "settings.hotkey.trigger.unbound.notice", bundle: AppResources.bundle),
                style.name)
        } else {
            comboNotice = nil
        }
        reload()
    }

    private func reload() {
        styles = (try? environment.styleRepository.fetchAll()) ?? []
        // 绑定不可解析告知（仅置不清——unbind 等路径自带各自的 notice 管理）
        if triggerBinding != nil, boundStyle == nil {
            comboNotice = String(
                localized: "settings.hotkey.trigger.fallback.notice", bundle: AppResources.bundle)
        }
    }

    /// 从 settings 校正本地镜像（界面三选一：引擎内部形态 holdOrToggle 归位到
    /// 默认档——录音键回落 doubleTap、风格键回落 toggle，不破坏引擎用法）。
    private func syncSettingsMirrors() {
        mode = environment.settings.hotkeyMode == .holdOrToggle
            ? .doubleTap : environment.settings.hotkeyMode
        styleMode = environment.settings.styleHotkeyMode == .holdOrToggle
            ? .toggle : environment.settings.styleHotkeyMode
        triggerCombo = environment.settings.recordingHotkeyCombo
        triggerBinding = environment.settings.triggerStyleBindingId
    }

    /// Debug 自动化：`--hotkey-capture` 首个风格行进捕获态（截图/走查用，仅 Debug 编译）。
    private var debugAutoCapture: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--hotkey-capture")
        #else
        false
        #endif
    }

    /// Debug 自动化：`--hotkey-trigger-menu` 触发键「修改」菜单自动弹出（仅 Debug 编译）。
    private var debugAutoOpenMenu: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--hotkey-trigger-menu")
        #else
        false
        #endif
    }

    /// Debug 自动化：`--hotkey-trigger-bound` 绑定态直入（截图/走查用，仅 Debug 编译；
    /// 只置本地镜像驱动 UI，不写 defaults/不动引擎——非侵入演示态）。
    private func debugPretendBoundIfNeeded() {
        #if DEBUG
        if CommandLine.arguments.contains("--hotkey-trigger-bound") {
            triggerBinding = TriggerKeyMenuModel.eligibleStyles(styles).first?.styleId
        }
        #endif
    }

    // MARK: - 测试你的快捷键（FR-017 / TASK-073：真听写输入框）

    /// 测试区 = 玻璃风多行输入框：聚焦后直接按快捷键听写，转写/润色文本经粘贴注入
    /// 落回本框（HUD 面板 nonactivating 不抢前台焦点，合成 ⌘V 目标=本窗口聚焦控件）；
    /// 框下 caption 实时显示引擎识别的组合（听写未完成也能确认热键生效）。
    /// 测试区（TASK-083 用户追裁「没有统一样式」：改为节标签 + SettingsCard，
    /// 与「录音快捷键」「风格快捷键」同款分组卡语言——标题 13.5 semibold tracking、
    /// 字段入卡、卡间 36/标签下 16 与全页一致）。
    @ViewBuilder private var testArea: some View {
        Text("settings.hotkey.test.title")
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.top, 36)
            .padding(.bottom, 16)

        SettingsCard {
            DictationTestField(
                text: $testInput,
                placeholder: String(localized: "settings.hotkey.test.placeholder", bundle: AppResources.bundle))
                .padding(.vertical, 14)

            if let recognizedText {
                Text(recognizedText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.num)
                    .padding(.bottom, 12)
            }
        }
    }

    /// 订阅引擎识别广播 → 「已识别：⌘ + ⌥ + 3 · 风格名（轻点）」形态展示（风格名现查仓库；
    /// TASK-090：多修饰全加号格式）。
    private func observeRecognitions() {
        pollObserving = true
        NotificationCenter.default.addObserver(
            forName: HotkeyEngine.recognizedNotification, object: nil, queue: .main
        ) { note in
            // 捕获 struct 视图副本：@State 为外置引用存储，写入有效；onDisappear 移除观察
            guard let key = note.userInfo?["key"] as? String,
                  let action = note.userInfo?["action"] as? String,
                  let role = note.userInfo?["role"] as? String else { return }
            if role == "recording" {
                recognizedText = String(
                    format: String(localized: "settings.hotkey.test.recognized.recording", bundle: AppResources.bundle),
                    key, action)
            } else {
                let storage = note.userInfo?["storage"] as? String
                let holder = styles.first { $0.hotkeyCombo == storage }
                recognizedText = String(
                    format: String(localized: "settings.hotkey.test.recognized.style", bundle: AppResources.bundle),
                    key, holder?.name ?? String(localized: "settings.hotkey.unbind", bundle: AppResources.bundle), action)
            }
        }
    }

    // MARK: - 权限失效横幅（SPEC 逐字 + 重新授权）

    private var permissionBanner: some View {
        NoticeBanner(
            title: "settings.hotkey.permission.lost",
            subtitle: "settings.hotkey.permission.lost.hint",
            actionTitle: "settings.hotkey.reauthorize",
            action: { environment.permissions.openAccessibilitySettings() },
            tone: .warn
        )
        .padding(.bottom, 14)
    }

    /// 权限态轮询（横幅随撤销/恢复动态出现消失；授权后热键 tap 由 AppDelegate 看守自愈）。
    private func startPermissionPolling() {
        pollTimer?.invalidate()
        let permissions = environment.permissions
        let engine = environment.hotkeyEngine
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            permissions.refresh()
            let broken = permissions.accessibility != .granted || engine.state != .running
            Task { @MainActor in permissionBroken = broken }
        }
    }

    private func refreshPermissionState() {
        permissionBroken = environment.permissions.accessibility != .granted
            || environment.hotkeyEngine.state != .running
    }
}

/// 测试听写输入框（TASK-073）：多行玻璃底输入——视觉走全站输入框语言
/// （常显 FieldBackground：Theme.field 底 + line2 细边；聚焦品牌蓝 ring，与 GlassField
/// 同 token）。文本层为全控 NSTextView（NSViewRepresentable）：SwiftUI TextEditor 在
/// macOS 上插入符/行高走 NSTextView 默认度量、与 .font 设置的文字不同源（用户实测
/// 光标与文字基线错位），自包后字体/内边距/插入符同源对齐；textContainerInset 与
/// placeholder 的 padding 用同一组常量，空态/正文原点严格一致。
/// 转写文本经合成 ⌘V 粘贴进来（NSTextView paste:），也可直接键入。
private struct DictationTestField: View {
    @Binding var text: String
    let placeholder: String
    @State private var focused = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    // 长文案按框宽换行（默认 Text 在 ZStack 里会单行截断出「…」）
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PlainTextEditor.insetX)
                    .padding(.vertical, PlainTextEditor.insetY)
                    .allowsHitTesting(false)
            }
            PlainTextEditor(text: $text) { focused = $0 }
        }
        .frame(minHeight: 76, maxHeight: 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FieldBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Theme.blueTintBorder : .clear, lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// PlainTextEditor / PlainTextView 已抽出共享（TASK-086，Dictately/UI/Support/PlainTextEditor.swift）
// ——听写测试框（DictationTestField）与风格编辑页 Prompt 大输入共用。

extension AppSettings.HotkeyMode {
    /// 快捷键页分段控件文案（TASK-040）。
    var title: String {
        switch self {
        case .hold: return String(localized: "settings.hotkey.mode.hold")
        case .toggle: return String(localized: "settings.hotkey.mode.toggle")
        case .doubleTap: return String(localized: "settings.hotkey.mode.doubleTap")
        case .holdOrToggle: return String(localized: "settings.hotkey.mode.holdOrToggle")
        }
    }
}
