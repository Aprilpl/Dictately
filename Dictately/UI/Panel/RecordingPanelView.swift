import SwiftUI
import AppKit

// 面板状态机（PanelPhase / PanelVisibilityPolicy / RecordingPanelModel）已下沉
// Core/Pipeline/RecordingPanelModel.swift（TASK-114）——Pipeline 是唯一写入方，
// 本文件只保留视图渲染与计时文案格式。

/// 面板计时文案格式（SPEC §2 逐字：录音 m:ss；转写/润色 1 位小数秒）。
enum PanelFormat {
    /// 录音计时：7000ms → "0:07"（走秒，m:ss）。
    static func recordingClock(ms: Int) -> String {
        let total = max(0, ms) / 1000
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// 转写/润色递增秒：1200ms → "1.2"（调用方拼「转写中 · %@s」）。
    static func seconds1dp(ms: Int) -> String {
        String(format: "%.1f", Double(max(0, ms)) / 1000)
    }
}

// MARK: - 面板视图

/// 录音悬浮面板内容（PRD §8 屏 A / SPEC §2 逐字文案，全走 Localizable.strings）：
/// 胶囊 320–380pt，左起 风格徽标 → 波形条区 → 计时/状态 → `Esc 取消` 角标。
/// 失败态：一行原因 + [重试] [关闭]（动作由 TASK-020 接线，先预留闭包）。
/// 视觉（TASK-038）：v2-glass 屏 A 转录——52pt 胶囊 + capsBg 叠毛玻璃 + 0.5px 亮边 +
/// 录音红 8pt 脉冲点；波形 live/静止均中性 fill 色（红仅留给脉冲点，SPEC §4 小面积）。
struct RecordingPanelView: View {
    let model: RecordingPanelModel
    /// 实时电平采样（AudioRecorderController.currentLevel 透传）。
    var level: () -> Float?
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    /// 录音红脉冲（1.4s ease-out 循环，v2-glass rayPulse）。
    @State private var pulse = false

    /// failed 带关联值，用模式匹配判等。
    private var isFailedPhase: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { _ in
            HStack(spacing: 13) {
                if model.phase == .recording {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulse ? 0.35 : 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                }

                if let badge = model.styleBadge, !isFailedPhase {
                    // 失败态不显示风格徽标（v2-glass：kind==='style' && phase!=='fail'）；
                    // fixedSize：用户风格名完整展示（2026-10-01 裁决），胶囊宽度随内容自适应
                    Chip(text: badge, tone: .blue)
                        .fixedSize()
                }

                WaveformView(isActive: model.phase == .recording, sample: level)

                statusArea

                if model.escHintVisible && (model.phase == .recording || model.phase == .cueing) {
                    escHint
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(minWidth: 320) // PRD §8：胶囊 320pt 起步，随徽标名自适应加宽
            .fixedSize(horizontal: true, vertical: false) // 取理想宽度（controller 按此调 NSPanel）
            .background(Capsule().fill(Theme.capsBg))
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            // 投影交给系统窗口阴影（controller hasShadow）：SwiftUI shadow 的扩散空间
            // 超出 NSPanel 边界会被硬裁剪，四角形成直角黑框（bug00012）
        }
    }

    /// 状态区（按阶段切换；文案逐字见 Localizable.strings 注释）。
    @ViewBuilder
    private var statusArea: some View {
        switch model.phase {
        case .idle, .cancelled:
            EmptyView()
        case .cueing:
            // 预滚「准备中」（TASK-075）：效果音播放中，播完切录音态（样式沿「转写中」文本位）。
            Text(String(localized: "panel.cueing"))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.text1)
        case .recording:
            let ms = elapsedMs(since: model.recordingStartedAt)
            Text(String(format: String(localized: "panel.status.recording"), PanelFormat.recordingClock(ms: ms)))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.text1)
        case .transcribing:
            let ms = elapsedMs(since: model.phaseStartedAt)
            Text(String(format: String(localized: "panel.status.transcribing"), PanelFormat.seconds1dp(ms: ms)))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.text1)
        case .polishing:
            let ms = elapsedMs(since: model.phaseStartedAt)
            Text(String(format: String(localized: "panel.status.polishing"), PanelFormat.seconds1dp(ms: ms)))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.text1)
        case .failed(let message):
            HStack(spacing: 10) {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.err)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // TASK-107（FR-019）：权限原因的失败不再死胡同——直链系统设置麦克风面板
                if model.failedWithPermissionIssue {
                    Button(String(localized: "panel.failed.authorize")) {
                        NSWorkspace.shared.open(PermissionChecker.microphoneSettingsURL)
                    }
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
                }
                Button(String(localized: "panel.failed.retry")) { onRetry?() }
                    .buttonStyle(.themePrimary)
                    .controlSize(.small)
                Button(String(localized: "panel.failed.close")) { onClose?() }
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        case .done:
            EmptyView() // 成功无文案（SPEC §2：文字就位、面板淡出，这就是品牌）
        }
    }

    /// `Esc 取消` 角标（kbd 键帽样式，§8 Components；v2-glass：键帽 + t3 小字）。
    private var escHint: some View {
        HStack(spacing: 5) {
            KbdKey(text: "Esc")
            Text(String(localized: "panel.esc.cancel"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
        }
    }

    private func elapsedMs(since date: Date?) -> Int {
        guard let date else { return 0 }
        return Int(Date.now.timeIntervalSince(date) * 1000)
    }
}
