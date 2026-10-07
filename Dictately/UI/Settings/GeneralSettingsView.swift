import SwiftUI
import ServiceManagement

/// 常规设置页（PRD FR-015 / roadmap TASK-039；TASK-074 卡片化对齐 AI 服务/快捷键页）：
/// 页头（「常规设置」+ 说明）+ 三张 SettingsCard 分组卡——「通用」（外观三段、登录启动）、
/// 「录音」（麦克风选择（默认 + 设备列表，失效回退默认并提示一次）、声音效果总开关、
/// 效果音选择（四枚打包 mp3，选中即试听 + ▶ 预览，TASK-075）、
/// 录音时静音（开录静音系统输出/结束恢复，SystemAudioMuter）、Esc 取消、录音上限下拉）、
/// 「输出与保留」（自动复制、文本输入方法只读（粘贴，v1）、音频保留下拉）。
/// 表单限宽 620pt、值列 330pt 左对齐块、末行 divider: false（与 LLMSettingsView 同款）。
/// 全部即改即生效（settings 直写）+ 持久化（UserDefaults）。
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    // 登录启动（SMAppService 真实状态）
    @State private var launchAtLogin = false
    @State private var launchAtLoginHint: LocalizedStringKey?

    // 麦克风列表（onAppear 刷新）
    @State private var microphones: [MicrophoneSelection.Device] = []

    /// 外观本地镜像驱动重绘（AppSettings 非 Observable；直写 defaults 不触发
    /// GlassSegmented 选中态刷新——「跟随系统」↔「浅色」同屏外观下尤为明显）。
    @State private var appearance: AppSettings.Appearance = .system

    /// 下拉 label 本地镜像（同上：Mic/保留/录音上限选中后 label 需即时刷新）。
    @State private var micDeviceUID = ""
    @State private var retentionDays = 30
    @State private var maxDuration = 240

    /// 效果音选择本地镜像（bug00013 规则：Menu label 直读 settings 不刷新）。
    @State private var soundEffect: EffectSound = .defaultSound
    /// 预览播放器（选中即试听 / ▶ 按钮；不受 soundEffects 总开关限制——关着也能试）。
    /// @State 持有单一实例：视图结构体重建不换播放器，播放期间实例/委托链稳定。
    @State private var previewPlayer = BundleEffectSoundPlayer()
    /// 预览播放中（▶ ↔ ■ 切换依据；播完/失败/手动停止经 completion 复位）。
    @State private var isPreviewing = false

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                // Debug 调试直入：`--general-bottom` 启动后自动滚到页尾（数据目录卡）——
                // 截图/走查用（SwiftUI 对合成滚轮/键盘滚动事件免疫，无法外部驱动）。
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--general-bottom") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation { proxy.scrollTo("data-folder-card", anchor: .bottom) }
                        }
                    }
                    #endif
                }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                micFallbackBanner

                sectionLabel("settings.general.section.general", topPadding: 24)

                SettingsCard {
                    SettingRow("settings.general.appearance", hint: "settings.general.appearance.hint") {
                        valueColumn(
                            GlassSegmented(
                                options: appearanceOptions,
                                selection: appearanceBinding,
                                small: true,
                                label: { $0.title }
                            ))
                    }
                    SettingRow("settings.general.launchAtLogin", hint: launchAtLoginHint) {
                        valueColumn(GlassToggle(isOn: launchAtLoginBinding, disabled: syncingLoginState))
                    }
                    // TASK-076：App 常驻入口（关窗不退出）——Dock 可藏、状态栏常驻；
                    // 副作用（activationPolicy/图标可见性）由 AppDelegate KVO 承担
                    SettingRow("settings.general.showInDock", hint: "settings.general.showInDock.hint") {
                        valueColumn(GlassToggle(isOn: boolBinding(\.showInDock)))
                    }
                    SettingRow("settings.general.showStatusBarIcon", hint: "settings.general.showStatusBarIcon.hint", divider: false) {
                        valueColumn(GlassToggle(isOn: boolBinding(\.showStatusBarIcon)))
                    }
                }

                sectionLabel("settings.general.section.recording", topPadding: 36)

                SettingsCard {
                    SettingRow("settings.general.microphone", hint: "settings.general.microphone.hint") {
                        valueColumn(micMenu)
                    }
                    SettingRow("settings.general.soundEffects", hint: "settings.general.soundEffects.hint") {
                        valueColumn(GlassToggle(isOn: boolBinding(\.soundEffects)))
                    }
                    SettingRow("settings.general.soundEffect", hint: "settings.general.soundEffect.hint") {
                        valueColumn(
                            HStack(spacing: 8) {
                                soundEffectMenu
                                soundEffectPreviewButton
                            })
                    }
                    SettingRow("settings.general.muteDuringRecording", hint: "settings.general.muteDuringRecording.hint") {
                        valueColumn(GlassToggle(isOn: boolBinding(\.muteDuringRecording)))
                    }
                    SettingRow("settings.general.escCancel", hint: "settings.general.escCancel.hint") {
                        valueColumn(GlassToggle(isOn: boolBinding(\.escCancelsRecording)))
                    }
                    SettingRow("settings.general.maxDuration", hint: "settings.general.maxDuration.hint", divider: false) {
                        valueColumn(maxDurationMenu)
                    }
                }

                sectionLabel("settings.general.section.output", topPadding: 36)

                SettingsCard {
                    SettingRow("settings.general.autoCopy", hint: "settings.general.autoCopy.hint") {
                        valueColumn(GlassToggle(isOn: boolBinding(\.autoCopyClipboard)))
                    }
                    // FR-015 只读展示项（v1 固定粘贴）
                    SettingRow("settings.general.textInputMethod", hint: "settings.general.textInputMethod.hint") {
                        valueColumn(
                            Chip(text: String(localized: "settings.general.textInputMethod.paste"), tone: .neutral))
                    }
                    SettingRow("settings.general.retention", hint: "settings.general.retention.hint", divider: false) {
                        valueColumn(retentionMenu)
                    }
                }

                // TASK-107（FR-019）：权限卡（用户裁决置于页尾）——麦克风/辅助功能状态自检
                // + 重新授权入口，失效（TCC 重置/换签名/更新）后不再只有死胡同报错。
                // PermissionChecker 是 @Observable，视图直读即随 refresh() 重绘
                // （不适用 AppSettings 本地镜像双写规则——该规则针对非 Observable 直写 defaults）。
                sectionLabel("settings.general.section.permissions", topPadding: 36)

                SettingsCard {
                    SettingRow("settings.general.permission.microphone", hint: micPermissionHint) {
                        valueColumn(
                            HStack(spacing: 8) {
                                permissionChip(environment.permissions.microphone == .granted)
                                micReauthorizeButton
                            })
                    }
                    SettingRow(
                        "settings.general.permission.accessibility",
                        hint: "settings.general.permission.accessibility.hint",
                        divider: false
                    ) {
                        valueColumn(
                            HStack(spacing: 8) {
                                permissionChip(environment.permissions.accessibility == .granted)
                                accessibilityAuthorizeButton
                            })
                    }
                }
                // TASK-103 追裁（2026-10-05 用户指令）：数据目录入口自「关于」页移入，
                // 置于常规设置最底部——「数据」小节 + 单行卡；路径作 hint 行展示
                // （开源用户定位 sqlite/录音文件用）。
                sectionLabel("settings.general.section.data", topPadding: 36)

                SettingsCard {
                    SettingRow(
                        title: String(localized: "settings.general.dataFolder"),
                        hint: AppDatabase.defaultPath().deletingLastPathComponent().path,
                        divider: false
                    ) {
                        valueColumn(
                            Button(String(localized: "settings.general.openDataFolder")) {
                                openDataFolder()
                            }
                            .buttonStyle(CompactGhostButtonStyle())
                        )
                    }
                }
                .id("data-folder-card")
            }
            // TASK-077 用户裁决：内容列弹性 + 居中；TASK-080 数值追裁：上限 800
            // （最大化窗口两侧留白各 ≈200pt）。窄窗自然收窄不溢出
            // （frame(maxWidth:) 语义，不用 minWidth 防溢出）。
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            // TASK-082：顶部间距 16→48（×3），底部维持 16
            .padding(.top, 48)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            microphones = MicrophoneList.availableDevices()
            appearance = environment.settings.appearance
            micDeviceUID = environment.settings.micDeviceUID
            retentionDays = environment.settings.audioRetentionDays
            maxDuration = environment.settings.maxRecordingSeconds
            soundEffect = environment.settings.soundEffect
            syncLaunchAtLoginFromSystem()
            environment.permissions.refresh() // 权限卡即时反映当前状态
            startPermissionPolling()
        }
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    // MARK: - 页头 / 小节标签 / 值列（与快捷键、AI 服务页同款）

    private var header: some View {
        // TASK-082：标题↔副标题间距 3→6（四页同款）
        VStack(alignment: .leading, spacing: 6) {
            Text("settings.general.title")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("settings.general.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }

    // TASK-081 用户追裁：卡片间小节标签上方间距 20→36（常规/AI 服务/快捷键三页统一）。
    // TASK-082 追裁：标签字号 12→13.5（醒目美观）、标签→卡片 8→16。
    private func sectionLabel(_ key: LocalizedStringKey, topPadding: CGFloat) -> some View {
        Text(key)
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.top, topPadding)
            .padding(.bottom, 16)
    }

    /// 值列宽度：卡内行控件统一放进同宽左对齐块，共享同一条左缘线
    /// （2026-10-01 用户裁决「左对齐」，与 AI 服务/快捷键页同款）。
    /// TASK-082 用户追裁：330→230——值列整体右移，标签↔控件间距加大；
    /// 分段选择器为弹性控件随块收窄，最宽固定控件（录制控件）留余量。
    private func valueColumn<V: View>(_ view: V) -> some View {
        view.frame(width: 230, alignment: .leading)
    }

    // MARK: - 外观（TASK-038 已接线；本地态 + settings 双写）

    private var appearanceOptions: [AppSettings.Appearance] {
        [.system, .light, .dark]
    }

    private var appearanceBinding: Binding<AppSettings.Appearance> {
        Binding(
            get: { appearance },
            set: {
                appearance = $0
                environment.settings.appearance = $0 // KVO → Theme.applyAppearance 即时生效
            })
    }

    // MARK: - 登录启动（SMAppService，双向同步）

    /// 注册/注销期间的短锁：防止系统回调把刚点击的状态又写回去。
    @State private var syncingLoginState = false

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { attemptSetLaunchAtLogin($0) })
    }

    /// 开：register()；关：unregister()。失败回滚并提示（裸二进制/权限异常场景）。
    private func attemptSetLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        launchAtLoginHint = nil
        syncingLoginState = true
        defer { syncingLoginState = false }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            environment.settings.launchAtLogin = on
        } catch {
            launchAtLogin = !on
            launchAtLoginHint = "settings.general.launchAtLogin.failed"
            AppLog.pipeline.error("SMAppService toggle failed: \(String(describing: error), privacy: .public)")
        }
        syncLaunchAtLoginHint()
    }

    /// 系统状态 → 开关（外部改动双向同步）：enabled/requiresApproval/notRegistered。
    private func syncLaunchAtLoginFromSystem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        environment.settings.launchAtLogin = launchAtLogin
        syncLaunchAtLoginHint()
    }

    private func syncLaunchAtLoginHint() {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            launchAtLoginHint = "settings.general.launchAtLogin.approval"
        default:
            if launchAtLoginHint != "settings.general.launchAtLogin.failed" {
                launchAtLoginHint = nil
            }
        }
    }

    // MARK: - 麦克风选择（默认 + 列表；失效回退提示一次）

    private var micMenu: some View {
        Menu {
            Button("settings.general.microphone.default") {
                micDeviceUID = ""
                environment.settings.micDeviceUID = ""
                environment.settings.micFallbackNoticePending = false
            }
            ForEach(microphones, id: \.uid) { mic in
                Button(mic.name) {
                    micDeviceUID = mic.uid
                    environment.settings.micDeviceUID = mic.uid
                    environment.settings.micFallbackNoticePending = false
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(micSelectionLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 190, alignment: .leading)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var micSelectionLabel: String {
        if micDeviceUID.isEmpty { return String(localized: "settings.general.microphone.default") }
        return microphones.first { $0.uid == micDeviceUID }?.name
            ?? String(localized: "settings.general.microphone.missing")
    }

    /// 回退横幅：录音时发现所选设备已失效（标记由 AVAudioEngineDevice 置位）。
    /// 展示一次后清除标记；随选择变更消失。卡片化后置于页头下（与快捷键页权限横幅同位）。
    @ViewBuilder
    private var micFallbackBanner: some View {
        if environment.settings.micFallbackNoticePending {
            NoticeBanner(title: "settings.general.microphone.fallback", tone: .warn)
                .padding(.bottom, 4)
                .onAppear { environment.settings.micFallbackNoticePending = false } // 提示一次
        }
    }

    // MARK: - 权限卡（TASK-107，FR-019）

    /// 权限态轮询 timer（页面可见期间 1s 重查，复刻快捷键页横幅轮询模式）。
    @State private var permissionPollTimer: Timer?

    /// 麦克风行 hint：已拒绝时提示去系统设置（系统不再弹窗）。
    private var micPermissionHint: LocalizedStringKey? {
        environment.permissions.microphone == .denied
            ? "settings.general.permission.microphone.denied.hint" : nil
    }

    private func permissionChip(_ granted: Bool) -> some View {
        Chip(
            text: String(localized: granted
                ? "settings.general.permission.granted"
                : "settings.general.permission.denied"),
            tone: granted ? .green : .orange)
    }

    /// 麦克风「重新授权」按状态分流（MicrophoneReauthAction 纯函数，单测覆盖）：
    /// 未决定 → App 内发起系统询问（弹窗就地出现）；已拒绝 → 深链系统设置麦克风面板；
    /// 已授权 → 无按钮（绿 chip 即反馈）。
    @ViewBuilder
    private var micReauthorizeButton: some View {
        switch PermissionChecker.microphoneReauthAction(for: environment.permissions.microphone) {
        case .none:
            EmptyView()
        case .requestInApp:
            Button(String(localized: "settings.general.permission.reauthorize")) {
                Task { await environment.permissions.requestMicrophoneAccess() }
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)
        case .openSystemSettings:
            Button(String(localized: "settings.general.permission.reauthorize")) {
                environment.permissions.openMicrophoneSettings()
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)
        }
    }

    /// 辅助功能「去授权」：深链系统设置（程序化授权 macOS 不允许）；
    /// 授权后 AppDelegate 看守自动重装热键 tap，页面轮询让 chip 变绿。
    @ViewBuilder
    private var accessibilityAuthorizeButton: some View {
        if environment.permissions.accessibility != .granted {
            Button(String(localized: "settings.general.permission.authorize")) {
                environment.permissions.openAccessibilitySettings()
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)
        }
    }

    /// 数据目录入口（TASK-103）：Finder 打开 ~/Library/Application Support/Dictately——
    /// 不存在先建（正常路径必存在，兜底首启异常）；目录本身即语义，不选中具体文件。
    private func openDataFolder() {
        let dir = AppDatabase.defaultPath().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
    /// 页面可见期间 1s 轮询权限态（主线程 timer；@Observable → 视图直读处自动重绘）。
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let permissions = environment.permissions
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            permissions.refresh()
        }
    }

    // MARK: - 通用绑定小件

    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { environment.settings[keyPath: keyPath] },
            set: { environment.settings[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - 效果音（TASK-075：四枚打包 mp3，选中即试听 + ▶ 预览）

    /// 效果音下拉（沿 micMenu/maxDurationMenu 同款规格；选中 → 本地镜像 + settings
    /// 双写 + 立即试听——听感即所见）。
    private var soundEffectMenu: some View {
        Menu {
            ForEach(EffectSound.allCases, id: \.self) { effect in
                Button(effect.displayName) {
                    soundEffect = effect
                    environment.settings.soundEffect = effect
                    startPreview(effect)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(soundEffect.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 110, alignment: .leading)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// ▶ 预览按钮：播放中切换为 ■ 停止态（再点即停），播完/停止后自动回 ▶（用户裁决）。
    private var soundEffectPreviewButton: some View {
        Button {
            if isPreviewing {
                previewPlayer.stopAll() // 未决 completion 即时回调 → 图标复位
            } else {
                startPreview(soundEffect)
            }
        } label: {
            Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28)
                .background(FieldBackground())
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 播一发预览：先停旧声（换目标不叠音），播放态置位，结束（播完/失败/手动停止）
    /// 由 completion 复位——回调恒在主线程（资源缺失/同步失败路径同样）。
    private func startPreview(_ effect: EffectSound) {
        previewPlayer.stopAll()
        isPreviewing = true
        previewPlayer.play(effect, volume: SoundFeedback.volume) { _ in
            isPreviewing = false
        }
    }

    /// 录音上限（2026-10-01 用户裁决：滑块 30–180 改下拉 90–300 步进 30，默认 180；
    /// 档位与就近归档逻辑在 AppSettings.maxRecordingSeconds）。
    private var maxDurationMenu: some View {
        Menu {
            ForEach(AppSettings.maxRecordingSecondOptions, id: \.self) { seconds in
                Button("\(seconds)s") {
                    maxDuration = seconds
                    environment.settings.maxRecordingSeconds = seconds
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(maxDuration)s")
                    .font(Theme.mono(12.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.num)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 110, alignment: .leading)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 音频保留（FR-018）：30 / 90 / 0=永久。
    private var retentionMenu: some View {
        Menu {
            ForEach([30, 90, 0], id: \.self) { days in
                Button(retentionLabel(days)) {
                    retentionDays = days
                    environment.settings.audioRetentionDays = days
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(retentionLabel(retentionDays))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 110, alignment: .leading)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "settings.general.retention.forever")
        case 30: return String(localized: "settings.general.retention.30")
        case 90: return String(localized: "settings.general.retention.90")
        default: return String(format: String(localized: "settings.general.retention.days"), days)
        }
    }
}

extension AppSettings.Appearance {
    /// 分段控件文案（TASK-038）。
    var title: String {
        switch self {
        case .system: return String(localized: "settings.general.appearance.system")
        case .light: return String(localized: "settings.general.appearance.light")
        case .dark: return String(localized: "settings.general.appearance.dark")
        }
    }
}

/// 紧凑幽灵按钮（2026-10-05 用户裁决：数据目录按钮 themeGhost 13pt/14×6 偏大）——
/// 同视觉小一号（12pt/10×4/radius 7）。**页面局部样式**：共享 GhostButtonStyle
/// 字号内边距写死且不理会 controlSize，勿为单点需求改共享件（权限卡按钮等仍在用）。
private struct CompactGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.dyn(light: .white.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.08))))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
