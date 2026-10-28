import AppKit
import SwiftUI

/// 录音悬浮面板的 NSPanel 持有者（FR-003）：
/// - 预创建常驻实例（`warmUp()`，避免首唤起时创建开销拖慢 <100ms 预算）
/// - `.nonactivatingPanel + borderless + floating`：出现/点击不激活本 App、不抢前台焦点
/// - show/hide 透明度动画 <120ms（FR-003）
/// - **光标所在屏**底部居中（PRD §8；2026-10-01 用户裁决：多屏跟随鼠标所在屏）
///
/// 出现/消失的**决策**不在本类（纯策略见 `PanelVisibilityPolicy`，驱动见 Pipeline TASK-015）；
/// 本类只做 AppKit 呈现。所有方法要求主线程调用。
///
/// PanelPresenting conformance 在本文件末尾（TASK-114 自 DictationPipeline.swift 迁回
/// UI 侧——Core 文件不写 UI 类型的 extension）。
final class RecordingPanelController {
    /// 透明度动画时长（FR-003 预算 <120ms，取 100ms）。
    static let animationDuration: TimeInterval = 0.1

    /// 面板初始/最小宽度（360 落在 PRD §8 胶囊 320–380pt 区间）；
    /// 实际宽度按内容自适应（风格徽标完整展示，上限 560）。高度 52 = 胶囊高度
    /// （视图 .frame(height: 52)）——窗口不留透明边，系统阴影按胶囊形状贴合投影。
    static let panelSize = NSSize(width: 360, height: 52)

    /// 底部留边（主屏可见区最低沿之上）。
    static let bottomMargin: CGFloat = 64

    /// 面板内容模型（Pipeline 与视图共用）。
    let model: RecordingPanelModel
    /// 电平采样透传（面板出现期间供波形；Pipeline 注入 recorder.currentLevel）。
    var levelSampler: () -> Float? = { nil }
    /// 失败态动作（TASK-020 接线）。
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    private var panel: RecordingPanel?

    init(model: RecordingPanelModel = RecordingPanelModel()) {
        self.model = model
    }

    /// 预创建常驻面板（App 启动时调用一次；幂等）。
    func warmUp() {
        assertMain()
        _ = ensurePanel()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 显示面板：按内容自适应宽度 → 光标所在屏底部居中 → makeKey（不激活 App，
    /// Esc 本地监听需要 key 状态）→ 透明度 0→1 动画（100ms）。
    func showPanel() {
        assertMain()
        let panel = ensurePanel()
        resizeToFitContent(panel)
        positionBottomCenter(panel)
        panel.alphaValue = 0
        // nonactivating 面板 makeKey 不激活本 App（前台 App 焦点保持，FR-003）
        panel.makeKey()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationAnimation(duration: Self.animationDuration) {
            panel.alphaValue = 1
        }
    }

    /// 隐藏面板：透明度 1→0 动画后 orderOut（Esc 提示等随面板一起消失）。
    func hidePanel() {
        assertMain()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationAnimation(duration: Self.animationDuration) {
            panel.alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - 内部

    /// 懒创建 NSPanel + SwiftUI 内容（进程内只创建一次 = 预创建常驻）。
    private func ensurePanel() -> RecordingPanel {
        if let panel { return panel }
        let panel = RecordingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true // 点击不抢 key（点击按钮时才成为 key）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: RecordingPanelView(
            model: model,
            level: { [weak self] in self?.levelSampler() ?? nil },
            onRetry: { [weak self] in self?.onRetry?() },
            onClose: { [weak self] in self?.onClose?() }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting
        self.panel = panel
        AppLog.pipeline.debug("recording panel created (persistent)")
        return panel
    }

    /// 按内容理想宽度调整面板（2026-10-01 裁决：风格徽标完整展示，胶囊宽度随内容自适应，
    /// 区间 320–560pt）。徽标在 enterRecording 时写入，每次显示前重算即可。
    private func resizeToFitContent(_ panel: RecordingPanel) {
        guard let hosting = panel.contentView as? NSHostingView<RecordingPanelView> else { return }
        hosting.setFrameSize(NSSize(width: Self.panelSize.width * 2, height: Self.panelSize.height))
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width = min(max(fitting.width, Self.panelSize.width), 560)
        let size = NSSize(width: width, height: Self.panelSize.height)
        hosting.setFrameSize(size)
        panel.setContentSize(size)
    }

    /// 面板定位（2026-10-01 用户裁决：**光标所在屏**底部居中——多屏时面板跟随
    /// 按下快捷键时鼠标所在的屏幕；旧实现固定 `NSScreen.main` = 键盘焦点屏，
    /// 会跟着 Dictately 主窗口走，双屏场景面板出现在错误屏幕）。
    /// 对齐该屏 visibleFrame 避开 Dock；鼠标未命中任何屏（理论上不发生）回退 main。
    private func positionBottomCenter(_ panel: NSPanel) {
        let screens = NSScreen.screens
        let screen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.minY + Self.bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 纯逻辑（单测）：鼠标点命中第几块屏（`NSMouseInRect` 语义，含边缘）。
    /// 返回 index 供 `screenIndex(containing:screens:)` 测试锁定多屏选择规则。
    static func screenIndex(containing point: NSPoint, screens: [NSRect]) -> Int? {
        screens.firstIndex { NSMouseInRect(point, $0, false) }
    }

    private func assertMain() {
        assert(Thread.isMainThread, "RecordingPanelController 必须主线程调用")
    }
}

/// 面板专用 NSPanel：borderless 默认不能成为 key，这里显式允许（Esc 本地监听依赖
/// 面板持有 key 状态；`.nonactivatingPanel` 保证成为 key 仍不激活本 App、不抢前台焦点）。
final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSAnimationContext {
    /// 透明度动画小工具（显式时长 + 平滑曲线；completion 可选）。
    static func runAnimationAnimation(
        duration: TimeInterval, _ changes: () -> Void, completionHandler: (() -> Void)? = nil
    ) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = duration
        if let completionHandler {
            NSAnimationContext.current.completionHandler = completionHandler
        }
        changes()
        NSAnimationContext.endGrouping()
    }
}

// MARK: - PanelPresenting（TASK-114 自 DictationPipeline.swift 迁回 UI 侧）

/// Core 的 Pipeline 经协议消费面板呈现（协议本体在 DictationPipeline.swift）；
/// conformance 留在 UI 侧——Core 文件不引用 UI 类型。
extension RecordingPanelController: PanelPresenting {}
