import Foundation

// MARK: - 通用偏好（TASK-115 自 AppSettings.swift 拆出，纯移动）

extension AppSettings {
    var appearance: Appearance {
        get { Appearance(rawValue: string(Key.appearance, default: "")) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// 所选麦克风（AVCaptureDevice.uniqueID；空 = 系统默认设备）。TASK-039/FR-015。
    var micDeviceUID: String {
        get { string(Key.microphoneDeviceUID, default: "") }
        set { defaults.set(newValue, forKey: Key.microphoneDeviceUID) }
    }

    /// 所选麦克风已失效回退默认的「提示一次」标记（设置页展示后清除）。
    var micFallbackNoticePending: Bool {
        get { bool(Key.microphoneFallbackNotice, default: false) }
        set { defaults.set(newValue, forKey: Key.microphoneFallbackNotice) }
    }

    var launchAtLogin: Bool {
        get { bool(Key.launchAtLogin, default: false) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// 程序坞图标（TASK-076，默认显示）：关 = accessory 常驻形态（无 Dock 图标/无应用
    /// 菜单栏），状态栏图标成为常驻入口。AppDelegate KVO 监听即时切换，无需重启。
    var showInDock: Bool {
        get { bool(Key.showInDock, default: true) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// 状态栏图标（TASK-076，默认显示）：菜单栏常驻入口（开始听写/主窗口/设置/退出）。
    var showStatusBarIcon: Bool {
        get { bool(Key.showStatusBarIcon, default: true) }
        set { defaults.set(newValue, forKey: Key.showStatusBarIcon) }
    }

    /// 最近选中的侧栏页（TASK-078）：存 RootView.Page.rawValue 字符串（本层不依赖
    /// UI 类型）；空/非法由 UI 层回退常规设置页。跨启动与关窗重开恢复最后浏览页。
    var sidebarLastPage: String {
        get { string(Key.sidebarLastPage, default: "") }
        set { defaults.set(newValue, forKey: Key.sidebarLastPage) }
    }

    var soundEffects: Bool {
        get { bool(Key.soundEffects, default: true) }
        set { defaults.set(newValue, forKey: Key.soundEffects) }
    }

    /// 请求日志（2026-10-10 用户裁决，默认开）：ASR/LLM 外发请求参数记录到数据目录
    /// request-log.jsonl（API Key 恒脱敏、音频只记元数据、5MB 轮转）。关 = 停止新增
    /// 写入（已有文件保留，数据文件夹手动删）。RequestLog 每次写入现读本值，即时生效。
    var requestLogEnabled: Bool {
        get { bool(Key.requestLogEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.requestLogEnabled) }
    }

    /// 省时估算的手打速度（TASK-133，默认 40 字/分钟）：getter 10–200 钳制
    /// （越界回边界值，非法/未写回默认）——省时横幅输入框的持久值。
    var statsTypingSpeed: Int {
        get { min(200, max(10, int(Key.statsTypingSpeed, default: 40))) }
        set { defaults.set(newValue, forKey: Key.statsTypingSpeed) }
    }

    /// 所选效果音（TASK-075 / 用户裁决：默认 Blip）。存储串 = EffectSound.rawValue
    /// （文件名，message 为小写开头）；非法/未存回退默认（沿 hotkeyMode 模式）。
    var soundEffect: EffectSound {
        get { EffectSound.from(storageName: string(Key.soundEffect, default: "")) }
        set { defaults.set(newValue.rawValue, forKey: Key.soundEffect) }
    }

    /// 文本输入方法（TASK-126，用户裁决模仿参考 App）：粘贴×4 布局键位 + 模拟按键。
    /// 非法/未存回退 .paste（沿 hotkeyMode 模式）。自动复制剪贴板已锁定常开（同任务
    /// 用户裁决：模拟按键模式也写剪贴板），autoCopyClipboard 属性随之退役。
    var textInputMethod: TextInputMethod {
        get { TextInputMethod(rawValue: string(Key.textInputMethod, default: "")) ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.textInputMethod) }
    }

    var escCancelsRecording: Bool {
        get { bool(Key.escCancelsRecording, default: true) }
        set { defaults.set(newValue, forKey: Key.escCancelsRecording) }
    }

    /// 录音时静音（TASK-074 / 用户裁决 2026-10-01；默认值 2026-10-06 改开）：开 = 开录时
    /// 静音系统默认输出设备、录音结束恢复原状（SystemAudioMuter 快照语义；用户已静音
    /// 的设备不掺和）。
    var muteDuringRecording: Bool {
        get { bool(Key.muteDuringRecording, default: true) }
        set { defaults.set(newValue, forKey: Key.muteDuringRecording) }
    }

    /// 录音上限档位（2026-10-01 用户裁决：滑块 30–180 改下拉 90–300 步进 30；
    /// 默认 240 系 2026-10-06 追裁，覆盖当日原始默认 180）。
    static let maxRecordingSecondOptions = [90, 120, 150, 180, 210, 240, 270, 300]

    var maxRecordingSeconds: Int {
        get {
            // 读取即就近归档：兼容旧滑块时代的任意值（如 30/45/165），UI 与录音停限一致。
            let raw = int(Key.maxRecordingSeconds, default: 240)
            return Self.maxRecordingSecondOptions.min {
                abs($0 - raw) < abs($1 - raw)
            } ?? 240
        }
        set { defaults.set(newValue, forKey: Key.maxRecordingSeconds) }
    }

    /// 语言提示，默认 ["zh","en"]；最多 4 个的上限校验在设置页做，此处只存取。
    var languageHints: [String] {
        get { defaults.stringArray(forKey: Key.languageHints) ?? ["zh", "en"] }
        set { defaults.set(newValue, forKey: Key.languageHints) }
    }

    /// 语言代码 → 显示名（设置页选项与 OpenAI 兼容 prompt 前缀共用，保证两处一致）。
    static func languageOptionLabel(for code: String) -> String? {
        switch code {
        case "zh": return "中文"
        case "en": return "英语"
        case "yue": return "粤语"
        case "ja": return "日语"
        default: return nil
        }
    }
}
