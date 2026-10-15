import CoreFoundation
import CoreGraphics
import Foundation

/// CGEventTap 热键引擎（FR-001 / 2026-10-01 裁决 #12）：session 级**可吞事件** tap，
/// 常驻监听录音触发键（默认右 ⌘，可自定义）与风格快捷键组合（可自定义）。
///
/// **独占语义（裁决 #12，AGENTS 硬约束）**：tap 以 `.defaultTap` 创建，对「当前已绑定的
/// 组合」的 keyDown/keyUp 返回 nil **吞掉**——事件到不了其他 App（我方必胜，不采用
/// Carbon「先注册者得」注册制）。边界铁律：
/// - 只吞已绑定组合（触发键普通组合形态 + 启用风格的组合；禁用风格视为未绑定不吞）；
/// - 修饰键 flagsChanged（含裸修饰键触发键，如右 ⌘ 双击）**永不吞**——吞修饰键状态变化
///   会破坏全系统修饰键跟踪；
/// - Esc（全局取消保留键）与未匹配按键**永不吞**，其他 App 行为不受影响。
///
/// 分层设计（可测性）：
/// - **判定全在纯逻辑**（HotkeyInterpreter/DoubleTapDetector/HoldOrToggleResolver/
///   HotkeyCombo，单测全覆盖，假时钟精确到毫秒边界）；
/// - 本类是薄壳：事件 → (组合匹配 + down/up 时间戳) → 后台串行队列解释 → 回调语义事件。
///
/// 线程模型：tap 回调在 tap 线程（同步决定是否吞，读 lock 保护的小状态）；
/// 判定器与解释器在 eventQueue 串行队列（resolver/lastTrigger 队列自有，无需加锁）。
///
/// 权限与失效（PRD §2 已知坑 #1、§11 热键表）：非 listen-only tap 与贴文字（合成 ⌘V）
/// 要求同一辅助功能权限——门槛对用户不变。创建失败 → permissionDenied + onPermissionLost；
/// 被系统超时禁用 → 立即重新 enable（无感自愈）；被失效 → onPermissionLost 横幅引导。
///
/// 手动验证项（需辅助功能权限）：docs/dev-notes/phase1-manual-checks.md
/// （双击右 ⌘ <100ms 回调、按住松开触发 stop、已绑定组合在 TextEdit 被吞、
/// 未匹配键直通、组合触发键按住/双击、录制期间引擎暂停）。
final class HotkeyEngine {
    enum State: Equatable {
        case idle
        case running
        case permissionDenied
    }

    private(set) var state: State = .idle

    /// 语义事件回调（**后台串行队列**调用；UI 操作需调用方自行切主线程）。
    var onEvent: ((HotkeyEvent) -> Void)?
    /// tap 创建失败或被系统失效（权限丢失）时回调一次（主线程）。
    var onPermissionLost: (() -> Void)?
    /// Esc keyDown（全局，面板显示期间的录音取消用，FR-003/§11）。
    /// 不吞事件：Esc 仍传给前台 App（其他 App 的取消语义不受影响）。
    var onEscape: (() -> Void)?
    /// 风格热键事件（可自定义组合，FR-008/裁决 #12；后台串行队列回调，UI 需切主线程）。
    var onStyleEvent: ((StyleHotkeyEvent) -> Void)?

    private let config: HotkeyConfig
    private let interpreter: HotkeyInterpreter
    /// 录音触发键组合（每次事件现读：设置页改键即时生效，沿 modeProvider 模式）。
    private let triggerProvider: () -> HotkeyCombo
    /// 风格热键模式（每次事件现读：设置页改模式即时生效，TASK-072 全局三选）。
    private let styleModeProvider: () -> AppSettings.HotkeyMode
    /// 事件解释队列（FR-001：热键处理在后台队列，不阻塞事件流）。
    private let eventQueue = DispatchQueue(
        label: "com.dictately.hotkey.events", qos: .userInteractive)
    /// tap 事件源所在线程的 RunLoop（start 时启动）。
    private var tapThread: Thread?
    private var eventTap: CFMachPort?
    /// stop() 主动失效与权限丢失失效的区分标记。
    private var isStopping = false
    private let lock = NSLock()

    // MARK: - lock 保护（tap 线程同步读 / 主线程写）

    /// 已绑定的启用风格组合（「是否吞」判定用；AppEnvironment 启动与 styles 变更后推入）。
    private var styleBindings: Set<HotkeyCombo> = []
    /// 录制控件激活期间：引擎全直通、零回调（防止重录已绑定组合被自己吞掉/触发听写）。
    private var captureActive = false
    /// down 已吞掉的主键 → 组合。keyUp 按键码对账收尾（修饰键按住期间松开不影响判定）；
    /// 孤儿条目（capture 中断等）在下次同键 down 时自然覆盖，自愈。
    private var consumedKeys: [Int: HotkeyCombo] = [:]

    // MARK: - eventQueue 串行队列自有

    /// 风格组合的解释器（与录音键同一套 HotkeyInterpreter，模式经 styleModeProvider
    /// 现读——按住/切换/双击三选，TASK-072；class 引用原地喂入，免值类型写回）。
    private var styleInterpreters: [HotkeyCombo: HotkeyInterpreter] = [:]
    /// 触发组合变更检测（变更即复位解释器，避免旧键的双击残留串扰新键）。
    private var lastTrigger: HotkeyCombo?

    init(
        config: HotkeyConfig = HotkeyConfig(),
        modeProvider: @escaping () -> AppSettings.HotkeyMode,
        triggerProvider: @escaping () -> HotkeyCombo = { .defaultTrigger },
        styleModeProvider: @escaping () -> AppSettings.HotkeyMode = { .toggle }
    ) {
        self.config = config
        self.interpreter = HotkeyInterpreter(config: config, modeProvider: modeProvider)
        self.triggerProvider = triggerProvider
        self.styleModeProvider = styleModeProvider
    }

    deinit {
        if eventTap != nil { stop() }
    }

    /// 推入当前生效的风格组合绑定（AppEnvironment 启动时与 styles 变更后调用；线程安全）。
    /// 未变更的组合保留既有解释器状态（双击残留等）；中途改绑属病态路径，重建即可。
    func refreshBindings(_ combos: Set<HotkeyCombo>) {
        lock.lock()
        styleBindings = combos
        lock.unlock()
        eventQueue.async { [weak self] in
            guard let self else { return }
            var interpreters: [HotkeyCombo: HotkeyInterpreter] = [:]
            for combo in combos {
                interpreters[combo] = self.styleInterpreters[combo]
                    ?? HotkeyInterpreter(config: self.config, modeProvider: self.styleModeProvider)
            }
            self.styleInterpreters = interpreters
        }
    }

    /// 录制控件暂停开关：true = 引擎全直通、零回调（线程安全）。
    func setCaptureActive(_ active: Bool) {
        lock.lock()
        captureActive = active
        lock.unlock()
    }

    /// 安装 tap 并开始监听（幂等）。返回 false = 无辅助功能权限（同时触发 onPermissionLost）。
    @discardableResult
    func start() -> Bool {
        assert(Thread.isMainThread, "HotkeyEngine.start 建议主线程调用（内部线程管理简单化）")
        lock.lock(); defer { lock.unlock() }
        guard eventTap == nil else { return true }

        // flagsChanged（裸修饰键触发键判定）+ keyDown/keyUp（Esc + 触发/风格组合，FR-003/008）。
        // .defaultTap：已绑定组合可吞事件（独占，裁决 #12）；不记录按键内容（PRD §7 Security）。
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue
                             | 1 << CGEventType.keyDown.rawValue
                             | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,      // session 级（本用户会话）
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate 返回 nil：几乎总是辅助功能未授权/被重置
            state = .permissionDenied
            AppLog.hotkey.error("event tap create failed — accessibility permission missing?")
            DispatchQueue.main.async { [weak self] in self?.onPermissionLost?() }
            return false
        }

        isStopping = false
        eventTap = tap
        CFMachPortSetInvalidationCallBack(tap, tapInvalidationCallback)

        let thread = Thread {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                AppLog.hotkey.error("runloop source create failed")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode)
            AppLog.hotkey.notice("hotkey tap installed (trigger + style combos, consuming bound combos)")
            CFRunLoopRun() // stop() 失效 tap 时由 invalidation callback 退出
        }
        thread.name = "com.dictately.hotkey.tap"
        thread.start()
        tapThread = thread
        state = .running
        return true
    }

    /// 卸载 tap（App 退出/权限重引导时）。
    func stop() {
        lock.lock()
        guard let tap = eventTap else {
            lock.unlock()
            return
        }
        isStopping = true
        eventTap = nil
        tapThread = nil
        state = .idle
        lock.unlock()

        CFMachPortInvalidate(tap) // 触发 invalidation callback → CFRunLoopStop
        AppLog.hotkey.notice("hotkey tap removed")
    }

    // MARK: - 事件处理（tap 线程同步判定「是否吞」→ 后台解释队列出语义事件）

    /// 「测试你的快捷键」识别广播（TASK-040 / FR-017）：引擎识别出可动作热键即发，
    /// 设置页订阅展示。key/storage = 触发键或组合的显示串/存储串，role 区分
    /// recording（录音键）与 style（风格键），action 为交互描述。
    /// 发送线程为 eventQueue（后台）——订阅方用主队列观察。
    static let recognizedNotification = Notification.Name("com.dictately.hotkey.recognized")

    fileprivate static func postRecognized(
        key: String, storage: String, role: String, action: String
    ) {
        NotificationCenter.default.post(
            name: recognizedNotification, object: nil,
            userInfo: ["key": key, "storage": storage, "role": role, "action": action])
    }

    /// flagsChanged 解析：裸修饰键形态的录音触发键（默认右 ⌘，泛化到左右 ⌘/⌥/⌃ 六键）。
    /// 其他修饰键变化直接放过。down/up 判定：该键家族 mask 是否置位——左右共掩码，
    /// 「左 ⌘ 按住 + 右 ⌘ 轻点」的 up 会被误判为 down（v1 已知局限，纯逻辑层可测）。
    /// 永不吞：修饰键状态变化直通（吞了会破坏全系统修饰键跟踪）。
    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        let capture = captureActive
        lock.unlock()
        guard !capture else { return }

        let trigger = triggerProvider()
        guard case .bare(let bare) = trigger.key, bare.keyCode == keycode else { return }
        let isDown = bare.isDown(flags: event.flags)
        // CGEvent.timestamp 单调（纳秒，系统启动起算），转 ms 喂纯逻辑层
        let timestampMs = Double(event.timestamp) / 1_000_000
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.resetInterpreterIfTriggerChanged(trigger)
            let events = self.interpreter.feed(isDown: isDown, timestampMs: timestampMs)
            for event in events {
                AppLog.hotkey.debug("hotkey event: \(String(describing: event), privacy: .public)")
                self.onEvent?(event)
                Self.postRecognized(
                    key: trigger.displayText, storage: trigger.storageString,
                    role: "recording", action: String(describing: event))
            }
        }
    }

    /// keyDown 判定：Esc（kVK_Escape = 53，录音取消）与触发/风格组合匹配。
    /// 返回 true = 吞掉（已绑定组合独占）；自动重复帧不重复喂判定器（防双击误触发）。
    @discardableResult
    fileprivate func handleKeyDown(_ event: CGEvent) -> Bool {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let timestampMs = Double(event.timestamp) / 1_000_000
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        lock.lock()
        let capture = captureActive
        let bindings = styleBindings
        lock.unlock()

        if keycode == HotkeyCombo.escapeKeyCode {
            if !capture {
                eventQueue.async { [weak self] in self?.onEscape?() }
            }
            return false // Esc 永不吞（其他 App 的取消语义不受影响）
        }
        guard !capture else { return false }

        let combo = HotkeyCombo(
            modifiers: HotkeyCombo.Modifier.set(from: event.flags), keyCode: keycode)
        let trigger = triggerProvider()
        if !trigger.isBareModifier, combo == trigger {
            lock.lock()
            consumedKeys[keycode] = combo
            lock.unlock()
            if !isRepeat {
                eventQueue.async { [weak self] in
                    self?.feedTriggerDown(trigger, timestampMs: timestampMs)
                }
            }
            return true
        }
        guard bindings.contains(combo) else { return false }
        lock.lock()
        consumedKeys[keycode] = combo
        lock.unlock()
        if !isRepeat {
            eventQueue.async { [weak self] in
                self?.feedStyle(combo, isDown: true, timestampMs: timestampMs)
            }
        }
        return true
    }

    /// keyUp 判定：仅当 down 已被本引擎吞掉时收尾吞掉（按键码对账——修饰键在按住期间
    /// 松开不影响组合归属）。返回 true = 吞掉。
    @discardableResult
    fileprivate func handleKeyUp(_ event: CGEvent) -> Bool {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let timestampMs = Double(event.timestamp) / 1_000_000

        lock.lock()
        let capture = captureActive
        let combo = consumedKeys.removeValue(forKey: keycode)
        lock.unlock()
        guard let combo else { return false } // down 未吞（未匹配/直通键）的 up 直通
        guard !capture else { return false }  // 录制中：up 直通且不再喂判定（状态自愈于下次按下）

        eventQueue.async { [weak self] in
            guard let self else { return }
            let trigger = self.triggerProvider()
            if !trigger.isBareModifier, combo == trigger {
                self.feedTriggerUp(trigger, timestampMs: timestampMs)
            } else {
                self.feedStyle(combo, isDown: false, timestampMs: timestampMs)
            }
        }
        return true
    }

    // MARK: - 语义判定（eventQueue 串行队列）

    private func feedTriggerDown(_ trigger: HotkeyCombo, timestampMs: Double) {
        resetInterpreterIfTriggerChanged(trigger)
        let events = interpreter.feed(isDown: true, timestampMs: timestampMs)
        for event in events {
            AppLog.hotkey.debug("hotkey event: \(String(describing: event), privacy: .public)")
            onEvent?(event)
            Self.postRecognized(
                key: trigger.displayText, storage: trigger.storageString,
                role: "recording", action: String(describing: event))
        }
    }

    private func feedTriggerUp(_ trigger: HotkeyCombo, timestampMs: Double) {
        resetInterpreterIfTriggerChanged(trigger)
        let events = interpreter.feed(isDown: false, timestampMs: timestampMs)
        for event in events {
            AppLog.hotkey.debug("hotkey event: \(String(describing: event), privacy: .public)")
            onEvent?(event)
            Self.postRecognized(
                key: trigger.displayText, storage: trigger.storageString,
                role: "recording", action: String(describing: event))
        }
    }

    /// 风格组合状态变化：经该组合的解释器产出语义事件（模式现读，TASK-072 三选），
    /// 映射为 StyleHotkeyEvent 逐个回调 + 识别广播（action 中文交互描述）。
    /// keyUp 在切换/双击模式下是空事件（解释器只看按下），吞事件对账不受影响。
    private func feedStyle(_ combo: HotkeyCombo, isDown: Bool, timestampMs: Double) {
        guard let interpreter = styleInterpreters[combo] else { return }
        let events = interpreter.feed(isDown: isDown, timestampMs: timestampMs)
        for event in events {
            guard let styleEvent = event.styleEvent(combo: combo) else { continue }
            AppLog.hotkey.debug("style hotkey event: \(String(describing: styleEvent), privacy: .public)")
            onStyleEvent?(styleEvent)
            let action: String
            switch styleEvent {
            case .start: action = "开始"
            case .stop: action = "结束"
            case .toggleStart: action = "触发"
            }
            Self.postRecognized(
                key: combo.displayText, storage: combo.storageString,
                role: "style", action: action)
        }
    }

    private func resetInterpreterIfTriggerChanged(_ current: HotkeyCombo) {
        if lastTrigger != current {
            lastTrigger = current
            interpreter.reset()
        }
    }

    /// tap 被系统禁用（回调超时）→ 立即重启用；这是对用户无感的自愈路径。
    fileprivate func reenableTapIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.hotkey.notice("event tap re-enabled after timeout disable")
    }

    /// tap 失效回调：主动 stop 不报警；权限丢失 → 发布信号（主线程）。
    fileprivate func handleTapInvalidated() {
        lock.lock()
        let deliberate = isStopping
        if !deliberate {
            state = .permissionDenied
            eventTap = nil
            tapThread = nil
        }
        lock.unlock()

        CFRunLoopStop(CFRunLoopGetCurrent()) // 结束 tap 线程
        guard !deliberate else { return }
        AppLog.hotkey.error("event tap invalidated — accessibility permission lost?")
        DispatchQueue.main.async { [weak self] in self?.onPermissionLost?() }
    }
}

// MARK: - C 回调桥（不能捕获上下文，经 userInfo 找回引擎）

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<HotkeyEngine>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout:
        engine.reenableTapIfNeeded()
        return Unmanaged.passUnretained(event)
    case .tapDisabledByUserInput:
        return Unmanaged.passUnretained(event)
    case .flagsChanged:
        engine.handleFlagsChanged(event)
        return Unmanaged.passUnretained(event) // 修饰键状态变化永不吞
    case .keyDown:
        return engine.handleKeyDown(event) ? nil : Unmanaged.passUnretained(event)
    case .keyUp:
        return engine.handleKeyUp(event) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

private func tapInvalidationCallback(machPort: CFMachPort?, info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let engine = Unmanaged<HotkeyEngine>.fromOpaque(info).takeUnretainedValue()
    engine.handleTapInvalidated()
}
