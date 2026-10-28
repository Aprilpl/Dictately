import Foundation
import Observation

/// 首次运行引导状态机（PRD FR-014 / SPEC 屏 F）：麦克风 → 辅助功能（2026-10-06
/// 用户裁决移除原第三步「ASR Key 测试」——Key 配置引导交由设置页承担）。
/// 纯逻辑与权限解耦（视图负责驱动真实权限），单测覆盖全部转移。
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case microphone = 0
        case accessibility = 1
    }

    private(set) var step: Step = .microphone
    /// 引导结束（完成或跳过）——视图据此写 `onboardingCompleted` 并关窗。
    private(set) var finished = false

    // MARK: - 转移（非法调用返回 false 不改变状态）

    /// 步骤 1 完成：麦克风已授权 → 进入辅助功能步骤。
    @discardableResult
    func microphoneGranted() -> Bool {
        guard step == .microphone else { return false }
        step = .accessibility
        return true
    }

    /// 步骤 2 完成：辅助功能已授权 → 引导结束。
    @discardableResult
    func accessibilityGranted() -> Bool {
        guard step == .accessibility, !finished else { return false }
        finished = true
        return true
    }

    /// 跳过（每步可用，US-008：主界面可用，设置页留未完成提示）。
    func skip() {
        finished = true
    }
}
