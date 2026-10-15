import CoreGraphics
import Foundation

/// 组合键统一建模（2026-10-01 裁决 #12：风格快捷键与录音触发键全部可自定义、可独占）。
///
/// 两种形态：
/// - **普通组合**：修饰键（⌘⌥⌃⇧）+ 主键（字母/数字/F 键等）——keyDown/keyUp 判定，
///   引擎匹配时**吞事件**（独占：其他 App 收不到；只吞已绑定组合是 AGENTS 硬约束）；
/// - **裸修饰键**（仅录音触发键）：左右 ⌘/⌥/⌃ 单键——flagsChanged 判定，
///   **永不吞**（吞修饰键状态变化会破坏全系统修饰键跟踪）。
///
/// 存储串规范：修饰 token 按 cmd>alt>ctrl>shift 固定序（`cmd+alt+18`）；裸修饰键单 token
/// （`rcommand`）；无修饰普通键仅键码数字（`96` = F5）。解析容忍任意 token 顺序，重编码恒规范化。
/// 键码取 Carbon 虚拟键（与键盘布局无关），显示名按 ANSI 布局映射。
struct HotkeyCombo: Hashable {
    // MARK: - 修饰键

    /// 参与组合的修饰键（大小写锁定/小键盘/fn 等噪声位不参与匹配）。
    /// allCases 顺序即存储串与显示的规范序（cmd>alt>ctrl>shift）。
    enum Modifier: String, CaseIterable, Hashable {
        case command = "cmd"
        case option = "alt"
        case control = "ctrl"
        case shift = "shift"

        var symbol: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .control: return "⌃"
            case .shift: return "⇧"
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .option: return .maskAlternate
            case .control: return .maskControl
            case .shift: return .maskShift
            }
        }

        /// 从事件 flags 归一化修饰集（忽略 capsLock/numPad/fn 等噪声位）。
        static func set(from flags: CGEventFlags) -> Set<Modifier> {
            var set = Set<Modifier>()
            for modifier in Modifier.allCases where flags.contains(modifier.flag) {
                set.insert(modifier)
            }
            return set
        }
    }

    /// 裸修饰键（仅录音触发键形态）。keycode 区分左右，mask 左右共用
    /// （「左 ⌘ 按住 + 右 ⌘ 轻点」误判是沿用 v1 的已知局限）。
    enum BareModifier: String, CaseIterable, Hashable {
        case rightCommand = "rcommand"
        case leftCommand = "lcommand"
        case rightOption = "roption"
        case leftOption = "loption"
        case rightControl = "rcontrol"
        case leftControl = "lcontrol"

        /// kVK_RightCommand=0x36 / kVK_Command=0x37（左）/ Option 0x3D/0x3A / Control 0x3E/0x3B。
        var keyCode: Int {
            switch self {
            case .rightCommand: return 0x36
            case .leftCommand: return 0x37
            case .rightOption: return 0x3D
            case .leftOption: return 0x3A
            case .rightControl: return 0x3E
            case .leftControl: return 0x3B
            }
        }

        /// 该键家族的共享 mask（左右不区分）。
        var flag: CGEventFlags {
            switch self {
            case .rightCommand, .leftCommand: return .maskCommand
            case .rightOption, .leftOption: return .maskAlternate
            case .rightControl, .leftControl: return .maskControl
            }
        }

        /// flagsChanged 事件的 flags 是否表示按下（up 时 mask 已清除）。
        func isDown(flags: CGEventFlags) -> Bool { flags.contains(flag) }

        static func first(forKeyCode keyCode: Int) -> BareModifier? {
            allCases.first { $0.keyCode == keyCode }
        }
    }

    /// 主键：普通键码或裸修饰键。
    enum Key: Hashable {
        case code(Int)
        case bare(BareModifier)
    }

    var modifiers: Set<Modifier>
    var key: Key

    init(modifiers: Set<Modifier> = [], keyCode: Int) {
        self.modifiers = modifiers
        self.key = .code(keyCode)
    }

    init(bare: BareModifier) {
        self.modifiers = []
        self.key = .bare(bare)
    }

    /// 主键键码（裸修饰键 = 修饰键键码）。
    var keyCodeValue: Int {
        switch key {
        case .code(let keyCode): return keyCode
        case .bare(let bare): return bare.keyCode
        }
    }

    var isBareModifier: Bool {
        if case .bare = key { return true }
        return false
    }

    // MARK: - 存储串

    /// 规范存储串（styles.hotkey_combo / UserDefaults 落盘形态）。
    var storageString: String {
        switch key {
        case .bare(let bare):
            return bare.rawValue
        case .code(let keyCode):
            let tokens = Modifier.allCases
                .filter { modifiers.contains($0) }
                .map(\.rawValue)
            return (tokens + [String(keyCode)]).joined(separator: "+")
        }
    }

    /// 解析存储串；非法串返回 nil（调用方按「未绑定/回退默认」处理）。
    init?(storageString: String) {
        let trimmed = storageString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let bare = BareModifier(rawValue: trimmed) {
            self.init(bare: bare)
            return
        }
        // 不省略空 token：严格拒绝 "cmd++18" 类畸形串（空 token 在下方逐一失败）
        let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = tokens.last, let keyCode = Int(last) else { return nil }
        var modifiers = Set<Modifier>()
        for token in tokens.dropLast() {
            guard let modifier = Modifier(rawValue: token) else { return nil }
            modifiers.insert(modifier)
        }
        self.init(modifiers: modifiers, keyCode: keyCode)
    }

    // MARK: - 显示与匹配

    /// 用户可见显示串（bug00008/00009 裁决：修饰键与主键间带加号「⌘ + 1」；
    /// TASK-090 追裁：**每个元素之间都有加号**——多修饰「⌘ + ⌥ + 3」，取代旧「⌘⌥ + 3」连写）。
    var displayText: String {
        switch key {
        case .bare(let bare):
            return bare.displayText
        case .code(let keyCode):
            let keyName = Self.keyDisplayName(keyCode) ?? "#\(keyCode)"
            guard !modifiers.isEmpty else { return keyName }
            let symbols = Modifier.allCases
                .filter { modifiers.contains($0) }
                .map(\.symbol)
                .joined(separator: " + ")
            return "\(symbols) + \(keyName)"
        }
    }

    /// keyDown/keyUp 事件是否与本组合精确匹配（普通组合形态；修饰集全等比较）。
    func matches(flags: CGEventFlags, keyCode: Int) -> Bool {
        guard case .code(let code) = key else { return false }
        return code == keyCode && Modifier.set(from: flags) == modifiers
    }

    /// 键码 → ANSI 布局显示名；未知键码回退 nil（displayText 显示 `#键码`）。
    static func keyDisplayName(_ keyCode: Int) -> String? {
        switch keyCode {
        case 0x00: return "A"
        case 0x0B: return "B"
        case 0x08: return "C"
        case 0x02: return "D"
        case 0x0E: return "E"
        case 0x03: return "F"
        case 0x05: return "G"
        case 0x04: return "H"
        case 0x22: return "I"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x25: return "L"
        case 0x2E: return "M"
        case 0x2D: return "N"
        case 0x1F: return "O"
        case 0x23: return "P"
        case 0x0C: return "Q"
        case 0x0F: return "R"
        case 0x01: return "S"
        case 0x11: return "T"
        case 0x20: return "U"
        case 0x09: return "V"
        case 0x0D: return "W"
        case 0x10: return "Y"
        case 0x06: return "Z"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"
        case 0x1D: return "0"
        case 0x18: return "="
        case 0x1B: return "-"
        case 0x21: return "["
        case 0x1E: return "]"
        case 0x29: return ";"
        case 0x27: return "'"
        case 0x2A: return "\\"
        case 0x2B: return ","
        case 0x2F: return "."
        case 0x2C: return "/"
        case 0x32: return "`"
        case 0x31: return "Space"
        case 0x24: return "↩"
        case 0x30: return "Tab"
        case 0x33: return "Delete"
        case 0x73: return "Home"
        case 0x77: return "End"
        case 0x74: return "PageUp"
        case 0x79: return "PageDown"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        case 0x69: return "F13"
        case 0x6B: return "F14"
        case 0x71: return "F15"
        case 0x6A: return "F16"
        case 0x40: return "F17"
        case 0x4F: return "F18"
        case 0x50: return "F19"
        default: return nil
        }
    }
}

extension HotkeyCombo.BareModifier {
    /// 裸修饰键显示名（「右 ⌘」沿用 v1 文案形态）。
    var displayText: String {
        switch self {
        case .rightCommand: return "右 ⌘"
        case .leftCommand: return "左 ⌘"
        case .rightOption: return "右 ⌥"
        case .leftOption: return "左 ⌥"
        case .rightControl: return "右 ⌃"
        case .leftControl: return "左 ⌃"
        }
    }
}

// MARK: - 录制校验（纯逻辑；提示文案由 UI 层映射）

extension HotkeyCombo {
    /// 校验失败原因（录制控件行内提示用）。
    enum RuleFailure: Equatable {
        /// 主键是保留键（Esc / 修饰键本身 / CapsLock / fn）——普通组合必须是非修饰主键。
        case reservedKey
        /// 缺少 ⌘/⌥/⌃（shift 单独 + 字母 = 大写输入，会吞正常打字；F 功能键豁免）。
        case needsCommandLikeModifier
        /// 风格快捷键不允许裸修饰键（仅录音触发键可用）。
        case bareModifierNotAllowed
    }

    /// 风格快捷键校验：非修饰主键 + Esc 等保留键禁用 + ⌘⌥⌃ 至少其一（F1–F19 豁免）。
    var styleRuleFailure: RuleFailure? {
        if isBareModifier { return .bareModifierNotAllowed }
        return normalKeyRuleFailure
    }

    /// 录音触发键校验：裸修饰键 或 合法普通组合。
    var triggerRuleFailure: RuleFailure? {
        if isBareModifier { return nil }
        return normalKeyRuleFailure
    }

    private var normalKeyRuleFailure: RuleFailure? {
        guard case .code(let keyCode) = key else { return nil }
        let isModifierKey = BareModifier.first(forKeyCode: keyCode) != nil
            || keyCode == Self.leftShiftKeycode || keyCode == Self.rightShiftKeycode
        if keyCode == Self.escapeKeyCode || isModifierKey
            || keyCode == Self.capsLockKeycode || keyCode == Self.functionModifierKeycode {
            return .reservedKey
        }
        if !modifiers.isDisjoint(with: [.command, .option, .control]) { return nil }
        return Self.isFunctionKey(keyCode) ? nil : .needsCommandLikeModifier
    }

    /// Esc = kVK_Escape（录音取消保留键，不可录制）。
    static let escapeKeyCode = 53
    /// kVK_CapsLock（状态键，不可作主键）。
    static let capsLockKeycode = 0x39
    /// kVK_Function（fn 修饰位，不可作主键）。
    static let functionModifierKeycode = 0x3F
    /// kVK_Shift / kVK_RightShift（左右 ⇧）。
    static let leftShiftKeycode = 0x38
    static let rightShiftKeycode = 0x3C

    /// F1–F19 功能键键码集合（无修饰也可作组合——系统级冲突面小）。
    static let functionKeyCodes: Set<Int> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65,
        0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50,
    ]

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        functionKeyCodes.contains(keyCode)
    }
}

extension HotkeyCombo {
    /// 内置风格默认组合（2026-10-01 用户裁决：保持 ⌘ + 1 / ⌘ + 2；kVK_ANSI_1/2 = 18/19。
    /// 2026-10-02 第三内置风格「中英互译」= ⌘ + 3，kVK_ANSI_3 = 20）。
    static let builtinIntent = HotkeyCombo(modifiers: [.command], keyCode: 18)
    static let builtinCasual = HotkeyCombo(modifiers: [.command], keyCode: 19)
    static let builtinTranslate = HotkeyCombo(modifiers: [.command], keyCode: 20)

    /// 录音触发键默认：右 ⌘（kVK_RightCommand = 0x36，FR-001 既有默认）。
    static let defaultTrigger = HotkeyCombo(bare: .rightCommand)
}
