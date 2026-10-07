import SwiftUI

/// 波形环形缓冲（PRD §8 屏 A：等宽竖条阵）。
/// 纯逻辑类：只维护固定长度电平历史，绘制与采样解耦，单测直接覆盖。
final class WaveformModel {
    /// 竖条数（2026-10-01 用户裁决由 28 减半：条点过密；14 根 3pt 条宽 + 2pt 间距）。
    static let defaultBarCount = 14

    /// 各条当前电平（0…1，index 0 最旧）；恒等于 barCount 个元素。
    private(set) var values: [CGFloat]
    private let count: Int

    init(barCount: Int = WaveformModel.defaultBarCount) {
        count = max(1, barCount)
        values = [CGFloat](repeating: 0, count: count)
    }

    /// 环形入条：尾部追加、头部淘汰，长度恒定；电平钳制到 0…1。
    func push(_ level: Float) {
        values.append(CGFloat(min(max(level, 0), 1)))
        if values.count > count {
            values.removeFirst(values.count - count)
        }
    }

    /// 当前快照（防御拷贝，绘制线程安全语义）。
    func snapshot() -> [CGFloat] { values }
}

/// Canvas 电平条波形（FR-002/FR-003）：30fps 采样绘制，-50..0dB 归一化由控制器完成。
///
/// - `isActive == true`（录音中）：按 TimelineView 30fps 采样 `sample()` 推入环形缓冲，
///   条形起伏（中性 fill 色，v2-glass WaveBars 转录）。
/// - `isActive == false`（转写中/失败等）：不推进缓冲，绘制静止低条（SPEC §2：
///   「转写中静止低条，失败平直」）。
struct WaveformView: View {
    /// 是否处于录音态（推进采样）。
    var isActive: Bool
    /// 归一化电平采样（0…1）；nil = 无数据（按 0 处理）。
    var sample: () -> Float?
    /// 条高（pt）；宽度由条数与可用宽推导。
    var barHeight: CGFloat = 22

    @State private var model = WaveformModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                if isActive {
                    // 采样推进在绘制闭包外的同步路径完成（见 onSchedule 注释）：
                    // TimelineView 每帧先推一条再绘制，等价 30fps 采样。
                    WaveformView.pushSample(model: model, sample: sample)
                }
                drawBars(in: &context, size: size)
            }
        }
        .frame(width: CGFloat(WaveformModel.defaultBarCount) * 5 - 2, height: barHeight)
    }

    /// 帧推进（抽出便于阅读；引用类型缓冲，无 SwiftUI 状态写入）。
    private static func pushSample(model: WaveformModel, sample: () -> Float?) {
        model.push(sample() ?? 0)
    }

    /// 条阵绘制：等宽竖条、居中排布、最小高度 4pt。
    /// 颜色（TASK-038，v2-glass WaveBars 转录）：live/静止均中性 fill 色
    /// （录音红只留给面板脉冲点，SPEC §4 语义色小面积原则）；静止态透明度 0.4。
    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let values = model.snapshot()
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let step = barWidth + gap
        let color = Theme.fill
        let opacity = isActive ? 0.85 : 0.4
        for (index, level) in values.enumerated() {
            let x = CGFloat(index) * step
            guard x + barWidth <= size.width else { continue }
            let active = isActive ? level : WaveformView.staticBarLevel(index: index)
            let height = max(4, active * size.height)
            let rect = CGRect(
                x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(opacity)))
        }
    }

    /// 非录音态的静止低条（交替 4/8pt，视觉上「停住的波形」而非空白）。
    private static func staticBarLevel(index: Int) -> CGFloat {
        index.isMultiple(of: 2) ? 0.18 : 0.36
    }
}
