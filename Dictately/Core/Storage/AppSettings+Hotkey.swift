import Foundation

// MARK: - 热键（TASK-115 自 AppSettings.swift 拆出，纯移动）

extension AppSettings {
    /// 触发方式，默认 doubleTap；读到非法原始值（手改 plist）回退默认。
    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: string(Key.hotkeyMode, default: "")) ?? .doubleTap }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    var hotkeyEnabled: Bool {
        get { bool(Key.hotkeyEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.hotkeyEnabled) }
    }

    /// 录音触发键组合（裁决 #12：默认右 ⌘ "rcommand"；裸修饰键或普通组合均可）。
    /// 非法串（手改 plist 等）读取时回退默认；引擎 triggerProvider 每次事件现读——改键即时生效。
    var recordingHotkeyCombo: HotkeyCombo {
        get { HotkeyCombo(storageString: string(Key.hotkeyCombo, default: "")) ?? .defaultTrigger }
        set { defaults.set(newValue.storageString, forKey: Key.hotkeyCombo) }
    }

    /// 风格快捷键触发方式（TASK-072 用户裁决：与录音键同款三选，全局一个模式、
    /// 默认 .toggle 每按翻转）。引擎 styleModeProvider 每次事件现读——改模式即时生效。
    var styleHotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: string(Key.styleHotkeyMode, default: "")) ?? .toggle }
        set { defaults.set(newValue.rawValue, forKey: Key.styleHotkeyMode) }
    }
}
