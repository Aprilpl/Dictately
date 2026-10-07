import Foundation
import Observation

// MARK: - 面板状态机（纯逻辑，与 NSPanel 解耦，单测全覆盖）
//
// 2026-10-06 TASK-114 自 UI/Panel/RecordingPanelView.swift 下沉 Core：
// DictationPipeline（唯一写入方）深度消费这三个类型，此前 Core 反向依赖 UI 文件。
// 本文件保持零 AppKit/SwiftUI 依赖（@Observable 属 Observation 框架）——
// 视图渲染（RecordingPanelView）与 NSPanel 呈现（RecordingPanelController）留在 UI 侧。

/// 面板/链路阶段（PRD §8 屏 A 状态机 + FR-003 完整状态机，TASK-015 Pipeline 复用同一状态源）。
enum PanelPhase: Equatable {
    case idle                        // Empty：不可见
    case cueing                      // 效果音预滚（TASK-075「先播音后开录」）：面板已现、波形静止 +「准备中」
    case recording                   // 波形起伏 + 计时 m:ss
    case transcribing                // 波形静止 + 「转写中 · 1.2s」递增
    case polishing                   // 风格口述：「润色中 · 0.8s」递增
    case failed(message: String)     // 错误一行文案 + [重试] [关闭]
    case done                        // 成功：无文案，300ms 后自动淡出
    case cancelled                   // 直接淡出
}

/// 面板可见性策略（纯函数）：驱动 NSPanel 显示/隐藏的唯一依据，
/// 与 NSPanel 完全解耦——单测直接打本枚举，AppKit 侧只管动画与 order。
enum PanelVisibilityPolicy {
    /// done 短暂可见（300ms 后由调用方调度 hide，FR-003「成功态 300ms 后自动淡出」）；
    /// cancelled 立即淡出（SPEC §2「Cancelled: 直接淡出」）。
    static func isVisible(_ phase: PanelPhase) -> Bool {
        switch phase {
        case .idle, .cancelled: return false
        case .cueing, .recording, .transcribing, .polishing, .failed, .done: return true
        }
    }

    /// 成功态自动隐藏延迟（FR-003：300ms）。
    static let doneAutoHideDelay: TimeInterval = 0.3
}

/// 录音面板模型：阶段转移 + 计时 + 风格徽标 + Esc 提示可见性。
/// Pipeline（TASK-015）是唯一写入方；视图只读。转移合法性集中在这里，
/// 非法转移（如 idle→transcribing）被拒绝并返回 false，便于上游记日志。
@Observable
final class RecordingPanelModel {
    private(set) var phase: PanelPhase = .idle
    /// 风格徽标（风格口述时显示风格名；v1 恒 nil，Phase 2 接入）。录音开始时设置。
    private(set) var styleBadge: String?
    /// Esc 取消提示是否可见（settings.escCancelsRecording，录音开始时快照）。
    private(set) var escHintVisible = true
    /// 录音开始时刻（m:ss 计时基准）。
    private(set) var recordingStartedAt: Date?
    /// 当前阶段进入时刻（转写/润色「x.xs」递增基准）。
    private(set) var phaseStartedAt: Date?

    // MARK: - 转移（返回是否成功；非法转移保持原状态）

    /// 效果音预滚态（TASK-075）：热键即进——面板照常 <100ms 出现（FR-003 预算不动），
    /// 效果音播完后由 Pipeline 调 enterRecording 接力。计时基准（recordingStartedAt）
    /// 在 enterRecording 才设置——提示音期间不计时。
    @discardableResult
    func enterCueing(style: String? = nil, escEnabled: Bool = true, now: Date = Date()) -> Bool {
        guard phase == .idle else { return false }
        phase = .cueing
        styleBadge = style
        escHintVisible = escEnabled
        phaseStartedAt = now
        return true
    }

    @discardableResult
    func enterRecording(style: String? = nil, escEnabled: Bool = true, now: Date = Date()) -> Bool {
        // idle → recording：直开路径（效果音关/骨架模式）；
        // cueing → recording：预滚结束开录（style/esc 快照与 cueing 时同值，重设无害）。
        guard phase == .idle || phase == .cueing else { return false }
        phase = .recording
        styleBadge = style
        escHintVisible = escEnabled
        recordingStartedAt = now
        phaseStartedAt = now
        return true
    }

    @discardableResult
    func enterTranscribing(now: Date = Date()) -> Bool {
        // recording → transcribing：正常链路；
        // failed → transcribing：面板「重试」重跑（TASK-020，FR-013）；
        // idle → transcribing：历史条目重试（TASK-034，FR-012——重跑链路无录音段）
        switch phase {
        case .idle, .recording, .failed:
            phase = .transcribing
            phaseStartedAt = now
            return true
        case .cueing, .transcribing, .polishing, .done, .cancelled:
            return false
        }
    }

    @discardableResult
    func enterPolishing(now: Date = Date()) -> Bool {
        // transcribing → polishing：正常风格链路；
        // failed → polishing：「重试润色」仅重跑 LLM 段（TASK-029，FR-012）；
        // idle → polishing：历史详情「重新生成」（TASK-098——与 enterTranscribing 的
        //   idle 放行 TASK-034 先例对称；此前漏放行导致 retryEntry(.polishOnly) 从
        //   idle 起点被门禁短路、LLM 根本没跑却回调假成功，勿收回）
        switch phase {
        case .idle, .transcribing, .failed:
            phase = .polishing
            phaseStartedAt = now
            return true
        case .cueing, .recording, .polishing, .done, .cancelled:
            return false
        }
    }

    /// 最近一次失败是否因麦克风权限（TASK-107，FR-019）——failed 态据此
    /// 显示「去授权」按钮；每次 enterFailed 重写，非 failed 态无人读取。
    private(set) var failedWithPermissionIssue = false

    @discardableResult
    func enterFailed(_ message: String, permissionIssue: Bool = false, now: Date = Date()) -> Bool {
        switch phase {
        case .cueing, .idle, .recording, .transcribing, .polishing, .failed:
            // idle → failed：录音启动失败（无权限/设备忙，PRD §11 权限表）
            // cueing → failed：预滚结束后开录失败（TASK-075）
            phase = .failed(message: message)
            phaseStartedAt = now
            failedWithPermissionIssue = permissionIssue
            return true
        case .done, .cancelled:
            return false
        }
    }

    @discardableResult
    func enterDone(now: Date = Date()) -> Bool {
        guard phase == .transcribing || phase == .polishing else { return false }
        phase = .done
        phaseStartedAt = now
        return true
    }

    @discardableResult
    func enterCancelled() -> Bool {
        guard phase != .idle && phase != .cancelled else { return false }
        phase = .cancelled
        return true
    }

    /// 回到 idle（淡出完成后由 Pipeline 调用；唯一能离开 done/cancelled 的路径）。
    @discardableResult
    func reset() -> Bool {
        guard phase != .idle else { return false }
        phase = .idle
        styleBadge = nil
        escHintVisible = true
        recordingStartedAt = nil
        phaseStartedAt = nil
        return true
    }
}
