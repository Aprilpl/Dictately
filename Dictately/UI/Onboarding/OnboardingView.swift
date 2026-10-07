import SwiftUI

/// 首次运行引导（PRD FR-014 / SPEC 屏 F：640×480 模态，两步指示器 ● ○，
/// 顶部 App 图标 + Dictately + tagline，每步「跳过」小字链接）。
/// 权限文案逐字取自 product-vision §4 语气表（= SPEC §2 屏 F 原文）。
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var model = OnboardingModel()
    @State private var pollTimer: Timer?
    @State private var axStuckHintVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 0.5)

            switch model.step {
            case .microphone: micStep.transition(.opacity)
            case .accessibility: accessibilityStep.transition(.opacity)
            }

            Rectangle().fill(Theme.line).frame(height: 0.5)
            footer
        }
        .background(GlassBackground())
        .frame(width: 640, height: 480)
        .onAppear(perform: arriveOnStep)
        .onChange(of: model.step) { _, _ in arriveOnStep() }
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: - 头部（图标 + 名称 + tagline；TASK-038 主题化）

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            Text("app.name")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("app.tagline")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
            stepIndicator
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// 两步指示器 ● ○（SPEC 屏 F；当前步 t1，未到步 30% fill）。
    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                let active = step.rawValue <= model.step.rawValue
                Circle()
                    .fill(active ? Theme.text1 : Theme.fill.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - 步骤 1 · 麦克风

    private var micStep: some View {
        stepContainer(title: "onboarding.step.mic.title") {
            Text("onboarding.step.mic.text")
                .fixedSize(horizontal: false, vertical: true)
            Button("onboarding.step.mic.button") {
                Task {
                    await environment.permissions.requestMicrophoneAccess()
                    if environment.permissions.microphone == .granted {
                        model.microphoneGranted()
                    }
                }
            }
            .disabled(environment.permissions.microphone == .granted)
            if environment.permissions.microphone == .granted {
                Text("onboarding.granted").foregroundStyle(Theme.ok)
            }
        }
    }

    // MARK: - 步骤 2 · 辅助功能（深链 + 自动检测）

    private var accessibilityStep: some View {
        stepContainer(title: "onboarding.step.ax.title") {
            Text("onboarding.step.ax.text")
                .fixedSize(horizontal: false, vertical: true)
            Button("onboarding.step.ax.button") {
                environment.permissions.openAccessibilitySettings()
            }
            switch environment.permissions.accessibility {
            case .granted:
                Text("onboarding.granted").foregroundStyle(Theme.ok)
            default:
                Text("onboarding.step.ax.checking").foregroundStyle(Theme.text3)
                    .task {
                        // 10 次检测（约 5s）仍未通过 → 给出重启指引（ad-hoc 重签后
                        // TCC 身份变化，勾选后通常需重启进程 AXIsProcessTrusted 才翻转）
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if environment.permissions.accessibility != .granted {
                            axStuckHintVisible = true
                        }
                    }
                if axStuckHintVisible {
                    Text("onboarding.step.ax.hint")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 底部（跳过 / 开始使用）

    private var footer: some View {
        HStack {
            Button("onboarding.skip") { finish(writeCompleted: true) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
            Spacer()
            Button("onboarding.start") { finish(writeCompleted: true) }
                .buttonStyle(.themePrimary)
                .controlSize(.large)
                .disabled(!model.finished)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 行为

    /// 进入某步时的到达逻辑：已授权的步骤自动前进（SPEC：接受弹窗后自动进入下一步）。
    /// 终态由 startAccessibilityPolling 授权即 finished，轮询 timer 自失效 +
    /// finish/onDisappear 兜底，无悬挂。
    private func arriveOnStep() {
        switch model.step {
        case .microphone:
            if environment.permissions.microphone == .granted { model.microphoneGranted() }
        case .accessibility:
            startAccessibilityPolling()
        }
    }

    /// 辅助功能授权自动检测（SPEC：打开系统设置后 1.5s 检测中 → 已授权自动继续）。
    private func startAccessibilityPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [environment, model] timer in
            environment.permissions.refresh()
            if environment.permissions.accessibility == .granted {
                timer.invalidate()
                model.accessibilityGranted()
            }
        }
    }

    /// 结束引导：写 onboardingCompleted（完成或跳过均不再弹出，PRD §8）并关窗。
    private func finish(writeCompleted: Bool) {
        if writeCompleted { environment.settings.onboardingCompleted = true }
        pollTimer?.invalidate()
        dismissWindow(id: "onboarding")
    }

    // MARK: - 布局小件

    private func stepContainer(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.text1)
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text2)
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
