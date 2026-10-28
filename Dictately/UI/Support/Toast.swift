import SwiftUI

/// 全站动作 Toast（TASK-097，2026-10-03 用户裁决；位置追裁：窗口正中）：浮动提醒，
/// ~1.6s 自动消失、重复触发重置计时。原型基准 docs/design-demos/ai-service-providers.html。
/// 表面沿 KeyToastView 先例（modalBg + 描边），比例按原型（内距 14·8 / 圆角 9 /
/// ✓ ok 色、info 态 ↻ t3 色）；随 AppEnvironment 注入、RootView 底部 overlay 承载。
@Observable
final class ToastPresenter {
    struct Message: Equatable {
        let text: String
        let isInfo: Bool
    }

    private(set) var current: Message?
    private var dismissTask: Task<Void, Never>?

    /// 显示动作反馈；再次调用替换当前内容并重置 1.6s 倒计时。
    func show(_ text: String, info: Bool = false) {
        dismissTask?.cancel()
        current = Message(text: text, isInfo: info)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// Toast 视图（RootView 最外层 overlay(alignment: .center) 承载，窗口正中）。
struct ToastView: View {
    let message: ToastPresenter.Message

    var body: some View {
        HStack(spacing: 8) {
            Text(message.isInfo ? "↻" : "✓")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(message.isInfo ? Theme.text3 : Theme.ok)
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.modalBg))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
