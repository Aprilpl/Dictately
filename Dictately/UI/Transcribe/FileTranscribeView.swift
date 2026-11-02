import SwiftUI

/// 文件转写页（TASK-150，方案 D = A+B 融合）：980 居中限宽双栏——
/// 左 = 单卡工作台（拖放 → 队列 → 结果），右 = 300pt 常驻转写历史面板；
/// 窄窗（< 双栏理想宽）自动上下堆叠（ViewThatFits）。第一期仅音频（mp3/wav/m4a）。
struct FileTranscribeView: View {
    @Environment(AppEnvironment.self) private var environment

    private var controller: FileTranscribeController { environment.fileTranscribe }

    /// 总结设置模态（TASK-152 页头入口；TASK-155 扩展为服务 + 双内置 Prompt）。
    @State private var showSummarySettings = false
    /// DEBUG 直入 `--transcribe-summary-pinned`：模态草稿预置钉选 + 专家预设
    /// （仅 @State 草稿演示，不写设置）。
    @State private var debugPinnedDraft = false
    @State private var escMonitor: Any?

    /// 双栏并排的内容区宽度门槛（2026-10-24 用户追裁：右栏必须常驻右侧、不得被
    /// 「挤到底下」）。ViewThatFits 按**理想宽度**测量——模型行提示文案等理想宽
    /// 把并排分支在默认窗宽下即误判放不下（图2 实案），故改明确门槛：
    /// ≥700pt 恒并排（默认窗 960 → 内容区 750 ✓）；<700（主窗最小宽 760 → 内容
    /// ~550）并排后左栏不足 240 不可用，右栏才移到下方。
    private static let sideBySideMinWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if geo.size.width >= Self.sideBySideMinWidth {
                        columnsSideBySide
                    } else {
                        VStack(spacing: 20) {
                            workbench
                            TranscribeHistoryPanelView()
                        }
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 48)
                .padding(.bottom, 16)
            }
            .onAppear {
                controller.bootstrapIfNeeded()
                seedDemoStateIfRequested()
            }
        }
        .overlay {
            // 总结设置模态（TASK-155 方案 A）：遮罩点击 / Esc / 取消三路收口
            if showSummarySettings {
                SummarySettingsEditorView(
                    settings: environment.settings,
                    initial: summaryEditorInitial,
                    keyConfigured: summaryKeyStates,
                    onCancel: { showSummarySettings = false },
                    onSave: { draft in
                        draft.apply(to: environment.settings)
                        environment.toast.show(String(localized: "transcribe.summary.toast.saved"))
                        showSummarySettings = false
                    })
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showSummarySettings)
        .onChange(of: showSummarySettings) { _, isActive in
            syncEscMonitor(isActive: isActive)
        }
        .onDisappear { syncEscMonitor(isActive: false) }
    }

    /// 并排双栏（左工作台弹性 × 右 300 面板）。空拖放态两卡**等高**
    /// （2026-10-24 用户追裁：初始两框长度一样——maxHeight ∞ + 竖向 fixedSize
    /// 取两卡较高者为准，短卡撑满）；其余态右栏保持自然高度（图3 形态）。
    /// 生效前提：右栏面板 body 内侧须有高度弹性 frame（TASK-165）——
    /// 此处的调用侧 frame 在 background 外侧，单独存在只会居中一个矮卡。
    @ViewBuilder
    private var columnsSideBySide: some View {
        if isFreshEmptyWorkbench {
            HStack(alignment: .top, spacing: 20) {
                workbench.frame(maxHeight: .infinity)
                TranscribeHistoryPanelView().frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 20) {
                workbench
                TranscribeHistoryPanelView()
            }
        }
    }

    /// 空拖放态（无历史查看、phase == empty）。
    private var isFreshEmptyWorkbench: Bool {
        controller.viewingEntryID == nil && controller.phase == .empty
    }

    private var workbench: some View {
        TranscribeWorkbenchView()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 页头（标题 + 副标题；「总结设置」常驻（TASK-152 方案 B）；查看历史条目时
    /// 右侧再出「＋ 新建转写」——原型 viewing 态）。
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("transcribe.title")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text("transcribe.subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            HStack(spacing: 10) {
                summarySettingsButton
                if controller.viewingEntryID != nil {
                    IconButton(icon: "plus", wide: true) {
                        controller.resetToEmpty()
                    }
                    .help(String(localized: "transcribe.new"))
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// 「总结设置」页头常驻入口（TASK-152 方案 B；TASK-157 图标钮宽版 44×28）：
    /// 任何页面状态可见；任一非默认（预设 ≠ 会议纪要助理，或已钉选服务）时
    /// 钮右上亮 7pt 蓝点（原型同形态）。
    private var summarySettingsButton: some View {
        IconButton(icon: "slider.horizontal.3", wide: true) {
            showSummarySettings = true
        }
        .help(String(localized: "transcribe.summary.settings.help"))
        .overlay(alignment: .topTrailing) {
            if controller.summarySettingsCustomized {
                Circle()
                    .fill(Theme.blue)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Theme.modalBg, lineWidth: 1.5))
                    .offset(x: 3, y: -3)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 模态打开用的草稿（DEBUG `--transcribe-summary-pinned` 时预置钉选 + 专家预设）。
    private var summaryEditorInitial: SummarySettingsEditorView.Draft {
        var draft = SummarySettingsEditorView.Draft.from(environment.settings)
        if debugPinnedDraft {
            draft.provider = .bailian
            draft.model = environment.settings.llmModelPreset(for: .bailian)
            draft.usesCustomModel = false
            draft.customModelID = ""
            draft.preset = .expert
        }
        return draft
    }

    /// 各 LLM 供应商是否已配置 Key（供应商菜单置灰判定；打开时快照传入模态）。
    private var summaryKeyStates: [AppSettings.LLMProvider: Bool] {
        ProviderSettingsSupport.keyStates(
            providers: AppSettings.LLMProvider.allCases,
            account: SecretAccount.llmAccount(for:),
            secrets: environment.secrets)
    }

    /// 模态 Esc 收口（沿 ASRSettingsView 删除确认同款 NSEvent 局部监视器）。
    private func syncEscMonitor(isActive: Bool) {
        if isActive, escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                showSummarySettings = false
                return nil
            }
        } else if !isActive, let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    // MARK: 调试直入（DEBUG；截图/走查瞬态用，仅空态注入一次）

    #if DEBUG
    private func seedDemoStateIfRequested() {
        let args = CommandLine.arguments
        // 总结设置模态直入（TASK-152 起保留参数名；--transcribe-summary-pinned
        // 预置钉选 QwenAI + 知识整理专家草稿，不写设置；可配 --transcribe-done 等组合）
        if args.contains("--transcribe-summary-pinned") {
            debugPinnedDraft = true
            showSummarySettings = true
        } else if args.contains("--transcribe-summary-prompt") {
            showSummarySettings = true
        }
        let pairs: [(String, String)] = [
            ("--transcribe-picked", "picked"),
            ("--transcribe-running", "running"),
            ("--transcribe-done", "done"),
            ("--transcribe-hist", "hist"),
            ("--transcribe-retrying", "retrying"),
        ]
        for (flag, state) in pairs where args.contains(flag) {
            controller.seedDemoState(state)
            return
        }
    }
    #else
    private func seedDemoStateIfRequested() {}
    #endif
}
