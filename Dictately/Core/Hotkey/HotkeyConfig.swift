import Foundation

// MARK: - 语义事件（引擎对外唯一输出）

/// 热键语义事件（FR-001）。「按键事件 → 语义动作」的判定全部在纯逻辑层完成，
/// CGEventTap 壳（HotkeyEngine）只做事件搬运。Esc 取消不在此层（Pipeline 本地捕获）。
enum HotkeyEvent: Equatable {
    /// hold 模式按下 / holdOrToggle 的 down：立即开始录音
    case start
    /// hold 模式松开 / holdOrToggle 按住 ≥ 阈值后松开：结束录音
    case stop
    /// 双击成立 / 切换翻转（FR-001 toggle 语义）：调用方按当前状态翻转
    /// （idle → 开始录音；recording → 停止并转写）
    case toggleStart
    /// holdOrToggle 快速轻点（down 后 <200ms up）。**不是翻转**：
    /// 若录音由紧邻的前一个 .start 启动 → 保持录音（切换开）；
    /// 若按下时已在录音 → 停止（切换关）。由 Pipeline 结合状态解释（TASK-015）。
    case tapCompleted
}

// MARK: - 风格热键事件（可自定义组合，FR-008 / 裁决 #12 / TASK-072 可选模式）

/// 风格热键语义事件（与录音热键的 HotkeyEvent 平行；携带触发命中的组合）。
/// TASK-072：模式由 settings.styleHotkeyMode 全局三选（按住/切换/双击，默认切换），
/// 解释器与录音键同一套（HotkeyInterpreter + styleModeProvider 每次事件现读）——
/// 按住：down 即开始该风格听写、up 结束；切换/双击：每次有效触发翻转
/// （idle → 开始该风格听写；录音中 → 停止并转写润色，由 Pipeline 结合状态解释）。
enum StyleHotkeyEvent: Equatable {
    case start(HotkeyCombo)
    case stop(HotkeyCombo)
    case toggleStart(HotkeyCombo)
}

// MARK: - 风格事件映射（引擎薄壳复用，纯逻辑可测）

extension HotkeyEvent {
    /// 录音语义事件 → 风格语义事件（附组合）。tapCompleted 是 holdOrToggle 专用轻点
    /// 语义，风格键三选模式不产出——映射为 nil 由调用方丢弃。
    func styleEvent(combo: HotkeyCombo) -> StyleHotkeyEvent? {
        switch self {
        case .start: return .start(combo)
        case .stop: return .stop(combo)
        case .toggleStart: return .toggleStart(combo)
        case .tapCompleted: return nil
        }
    }
}

// MARK: - 配置

/// 热键配置（FR-001）：录音触发键与风格组合均可自定义（2026-10-01 裁决 #12），
/// 触发键默认右 ⌘（keycode 0x36 = kVK_RightCommand，HotkeyCombo.defaultTrigger），
/// 风格组合默认 ⌘+1 / ⌘+2（keycode 18 / 19 = kVK_ANSI_1 / 2）。
/// 两个时间阈值可注入——单测用边界值锁定判定逻辑。
///
/// 独占机制裁决：**不采用** Carbon RegisterEventHotKey（「先注册者得」语义，冲突时我方
/// 反而失效）；由 HotkeyEngine 的可吞事件 CGEventTap 对已绑定组合吞事件实现独占。
struct HotkeyConfig {
    /// 右 ⌘ 键码（Carbon kVK_RightCommand = 0x36）。
    static let rightCommandKeycode: Int = 0x36

    /// 双击判定窗口（FR-001：间隔 <500ms）。恰好等于阈值不算双击（单测锁定）。
    var doubleTapIntervalMs: Double = 500

    /// 「按住或切换」识别阈值（FR-001：down 后 200ms 内 up = 切换；
    /// 按住 ≥200ms 松开 = hold 结束——200ms 本身归 hold，单测锁定）。
    var holdThresholdMs: Double = 200

    /// 录音热键模式（默认 doubleTap，与 settings.hotkeyMode 默认一致）。
    var mode: AppSettings.HotkeyMode = .doubleTap

    init(
        doubleTapIntervalMs: Double = 500,
        holdThresholdMs: Double = 200,
        mode: AppSettings.HotkeyMode = .doubleTap
    ) {
        self.doubleTapIntervalMs = doubleTapIntervalMs
        self.holdThresholdMs = holdThresholdMs
        self.mode = mode
    }
}

// MARK: - 纯逻辑判定器（单测全覆盖，无任何系统依赖）

/// 双击判定器：只喂「按下」事件；两次按下间隔 < intervalMs 判定双击。
struct DoubleTapDetector {
    let intervalMs: Double
    /// 上一次按下时间（ms）；双击成立后清空（第三次按下重新起算）。
    private(set) var lastDownMs: Double?

    init(intervalMs: Double) {
        self.intervalMs = intervalMs
    }

    /// 喂入一次按下；返回 true 表示与上一次构成双击。
    mutating func feedDown(_ timestampMs: Double) -> Bool {
        if let last = lastDownMs, timestampMs - last < intervalMs {
            lastDownMs = nil // 双击已消费：三连击的第三次按新单击处理
            return true
        }
        lastDownMs = timestampMs
        return false
    }

    /// 外部状态复位（模式切换/引擎重装时）。
    mutating func reset() { lastDownMs = nil }
}

/// 「按住或切换」识别输出（FR-001 自动识别语义）。
enum HoldOrToggleEvent: Equatable {
    /// down：立即开始（hold 与 toggle 的共同前缀，反馈不打折）
    case pressed
    /// down 后 <200ms up：切换翻转——由 pressed 启动的保持进行，idle 时按下则翻转停止
    case toggleTap
    /// 按住 ≥200ms 后 up：hold 结束 → 停止
    case holdEnded
}

/// 按住/切换识别器：喂 down/up 时间戳，输出三态语义。
struct HoldOrToggleResolver {
    let thresholdMs: Double
    private(set) var downMs: Double?

    init(thresholdMs: Double) {
        self.thresholdMs = thresholdMs
    }

    mutating func feedDown(_ timestampMs: Double) -> HoldOrToggleEvent? {
        downMs = timestampMs
        return .pressed
    }

    /// 无 down 的 up（序列错乱/未关心）返回 nil。
    mutating func feedUp(_ timestampMs: Double) -> HoldOrToggleEvent? {
        guard let down = downMs else { return nil }
        downMs = nil
        // FR-001 措辞：200ms 内 = 切换；≥200ms = hold。200ms 整归 hold。
        return (timestampMs - down) < thresholdMs ? .toggleTap : .holdEnded
    }

    mutating func reset() { downMs = nil }
}

/// 热键解释器：原始修饰键事件（isDown + 时间戳）→ 语义 HotkeyEvent。
/// 模式每次 feed 时经 `modeProvider` 现读（设置页改模式即时生效，FR-017）。
final class HotkeyInterpreter {
    private let config: HotkeyConfig
    private let modeProvider: () -> AppSettings.HotkeyMode
    private var doubleTapDetector: DoubleTapDetector
    private var holdOrToggleResolver: HoldOrToggleResolver

    init(config: HotkeyConfig = HotkeyConfig(), modeProvider: @escaping () -> AppSettings.HotkeyMode) {
        self.config = config
        self.modeProvider = modeProvider
        self.doubleTapDetector = DoubleTapDetector(intervalMs: config.doubleTapIntervalMs)
        self.holdOrToggleResolver = HoldOrToggleResolver(thresholdMs: config.holdThresholdMs)
    }

    /// 复位内部检测状态（触发键/模式变更时调用，避免旧键的双击残留串扰新键）。
    func reset() {
        doubleTapDetector.reset()
        holdOrToggleResolver.reset()
    }

    /// 喂入一次触发键状态变化；返回 0…n 个语义事件（按发生顺序）。
    func feed(isDown: Bool, timestampMs: Double) -> [HotkeyEvent] {
        switch modeProvider() {
        case .doubleTap:
            // 只看按下；双击成立 → 翻转
            guard isDown, doubleTapDetector.feedDown(timestampMs) else { return [] }
            return [.toggleStart]
        case .hold:
            return isDown ? [.start] : [.stop]
        case .toggle:
            return isDown ? [.toggleStart] : []
        case .holdOrToggle:
            if isDown {
                _ = holdOrToggleResolver.feedDown(timestampMs)
                return [.start] // down 即开始（hold/tap 共同前缀，反馈不打折）
            } else {
                guard let resolved = holdOrToggleResolver.feedUp(timestampMs) else { return [] }
                switch resolved {
                case .toggleTap: return [.tapCompleted]
                case .holdEnded: return [.stop]
                case .pressed: return [] // 不可达（up 路径）
                }
            }
        }
    }
}
