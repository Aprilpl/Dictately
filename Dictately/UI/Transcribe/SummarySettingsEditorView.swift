import SwiftUI

/// 文件转写 · 总结设置模态（TASK-155 方案 A 单模态三段；原型
/// docs/design-demos/transcribe-summary-settings.html；2026-10-25 追裁：内置预设
/// 只读展示、fork 机制退役）：
/// ①「AI 服务」两行——供应商（跟随全局默认 / 六家，未配置置灰）+ 模型（预设下拉 +
/// 自定义 ID，交互沿 AI 服务页 §26 分离惯例）；②「总结 Prompt」三段分段（会议纪要
/// 助理默认 / 知识整理专家 / 自定义）+ 职能副行；③ 内置预设 = 只读文案展示（不
/// 允许输入）；自定义 = 190pt 编辑器（§78 语义全保：n/8000 硬截断、空值禁存、
/// 聚焦蓝 ring）。「恢复默认」= 预设回会议纪要助理 + 服务回跟随全局 + 模型三键
/// 复位。遮罩 / Esc（父层局部监视器）/ 取消三路收口沿 §69 形态。
struct SummarySettingsEditorView: View {
    /// 模态草稿：打开时自设置快照，保存时整体回写（取消即弃）。
    struct Draft {
        var preset: AppSettings.SummaryPreset
        var customText: String
        /// nil = 跟随「AI 服务」当前配置（默认）。
        var provider: AppSettings.LLMProvider?
        /// 钉选家模型快照三键（镜像 llm.model.preset/usesCustom/customID；仅钉选时有意义）。
        var model: String
        var usesCustomModel: Bool
        var customModelID: String

        /// 自当前设置快照：预设带 TASK-152 存量派生（custom 文案带入）；钉选家模型
        /// 三键读总结自己的快照键（空预设 ID → 该家「AI 服务」页当前下拉状态）。
        static func from(_ settings: AppSettings) -> Draft {
            let pinned = settings.transcribeSummaryPinnedProvider
            let model = settings.transcribeSummaryModel
            return Draft(
                preset: settings.transcribeSummaryPreset,
                customText: settings.transcribeSummaryPrompt,
                provider: pinned,
                model: !model.isEmpty ? model : (pinned.map { settings.llmModelPreset(for: $0) } ?? ""),
                usesCustomModel: pinned.map { settings.llmUsesCustomModel(for: $0) } ?? false,
                customModelID: pinned.map { settings.llmModelCustomID(for: $0) } ?? "")
        }

        /// 回写设置。custom 预设才写 prompt 文案（切内置预设不覆盖存量自定义文案，
        /// 切回自定义可复原——§26 值保留惯例）；跟随全局时模型三键复位防残留旧快照；
        /// custom 端点供应商无预设，模型恒走自定义 ID。
        func apply(to settings: AppSettings) {
            settings.transcribeSummaryPreset = preset
            if preset == .custom {
                settings.transcribeSummaryPrompt = customText
            }
            settings.transcribeSummaryPinnedProvider = provider
            if let provider {
                settings.transcribeSummaryModel = model
                settings.transcribeSummaryUsesCustomModel = provider.modelPresets.isEmpty || usesCustomModel
                settings.transcribeSummaryCustomModelID = customModelID
            } else {
                settings.transcribeSummaryModel = ""
                settings.transcribeSummaryUsesCustomModel = false
                settings.transcribeSummaryCustomModelID = ""
            }
        }
    }

    /// 设置快照来源（钉选瞬间的模型快照、全局供应商/模型显示、跟随项副注）。
    let settings: AppSettings
    let initial: Draft
    /// 各供应商是否已配置 Key（未配置项菜单置灰；FileTranscribeView 打开时算好传入）。
    let keyConfigured: [AppSettings.LLMProvider: Bool]
    let onCancel: () -> Void
    let onSave: (Draft) -> Void

    private static let promptLimit = 8000

    // MARK: - 草稿状态（@State 镜像 initial，会话内自持）

    @State private var preset: AppSettings.SummaryPreset
    /// 自定义文案（跨预设切换保留；保存时仅 custom 预设采用，编辑器直绑）。
    @State private var customDraft: String
    @State private var provider: AppSettings.LLMProvider?
    @State private var model: String
    @State private var usesCustomModel: Bool
    @State private var customModelID: String
    @State private var focused = false

    init(
        settings: AppSettings,
        initial: Draft,
        keyConfigured: [AppSettings.LLMProvider: Bool],
        onCancel: @escaping () -> Void,
        onSave: @escaping (Draft) -> Void
    ) {
        self.settings = settings
        self.initial = initial
        self.keyConfigured = keyConfigured
        self.onCancel = onCancel
        self.onSave = onSave
        _preset = State(initialValue: initial.preset)
        _customDraft = State(
            initialValue: initial.preset == .custom
                ? Self.seededCustomDraft(initial.customText)
                : initial.customText)
        _provider = State(initialValue: initial.provider)
        _model = State(initialValue: initial.model)
        _usesCustomModel = State(initialValue: initial.usesCustomModel)
        _customModelID = State(initialValue: initial.customModelID)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.maskScrim)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            serviceRows
                .padding(.top, 16)
            presetSection
                .padding(.top, 16)
            promptField
                .padding(.top, 8)
            footer
                .padding(.top, 10)
        }
        .padding(.top, 20)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.modalBg)
                .shadow(color: .black.opacity(0.36), radius: 45, x: 0, y: 30)
                .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .contentShape(Rectangle())
        // 吞卡内点击——防冒泡到遮罩误取消（§69 同款；NSTextView 自身消费点击不受影响）
        .onTapGesture {}
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// 头部：滑杆图标（蓝 tint 槽）+ 标题 + 副标题（服务选择 + system/user 契约）。
    private var head: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.blue)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blueTintBg))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.blueTintBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text("transcribe.summary.settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text("transcribe.summary.settings.subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(4.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: ① AI 服务两行（label 58pt 左 · 控件右；原型 flab/menu-btn 同构）

    private var serviceRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                rowLabel("transcribe.summary.service")
                providerMenu
            }
            HStack(spacing: 12) {
                rowLabel("transcribe.summary.model")
                modelControl
            }
            if showsCustomModelIDRow {
                customModelIDRow
            }
        }
    }

    private func rowLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.text2)
            .frame(width: 58, alignment: .leading)
    }

    /// 供应商下拉：首项跟随全局（附全局家 · 模型副注）+ 六家（未配置置灰）。
    /// 钉选瞬间模型三键快照重置为该家「AI 服务」页当前下拉状态（快照语义）。
    private var providerMenu: some View {
        Menu {
            Button(action: { followGlobal() }) {
                Text(String(
                    format: String(localized: "transcribe.summary.service.follow.item"),
                    settings.llmProvider.displayName,
                    settings.llmModel(for: settings.llmProvider)))
            }
            ForEach(AppSettings.LLMProvider.allCases, id: \.self) { item in
                if keyConfigured[item] == true {
                    Button(item.displayName) { pin(item) }
                } else {
                    // 未配置不可选（Key 只在「AI 服务」页配置；插值走 format 键，§76）
                    Button(String(
                        format: String(localized: "transcribe.summary.service.unconfigured.format"),
                        item.displayName)) {}
                        .disabled(true)
                }
            }
        } label: {
            menuLabel(
                text: provider.map(\.displayName)
                    ?? String(localized: "transcribe.summary.service.follow"),
                mono: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 模型行：跟随全局 → 禁用态显示全局模型；钉选 → 预设下拉（末项「自定义模型」）
    /// 或 custom 端点纯输入（沿 AI 服务页模型行同构）。
    @ViewBuilder
    private var modelControl: some View {
        if let pinned = provider {
            if pinned.modelPresets.isEmpty {
                GlassField(
                    "transcribe.summary.model.customid.placeholder",
                    text: $customModelID,
                    invalid: customModelInvalid)
            } else {
                Menu {
                    ForEach(pinned.modelPresets, id: \.id) { item in
                        Button(item.label) {
                            model = item.id
                            usesCustomModel = false
                        }
                    }
                    Button(String(localized: "settings.llm.model.custom")) {
                        usesCustomModel = true
                    }
                } label: {
                    menuLabel(
                        text: usesCustomModel
                            ? String(localized: "settings.llm.model.custom")
                            : ProviderSettingsSupport.menuLabel(for: model),
                        mono: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // 跟随全局：模型由「AI 服务」页决定，此处只读展示（禁用态玻璃底）。
            HStack(spacing: 8) {
                Text(ProviderSettingsSupport.menuLabel(
                    for: settings.llmModel(for: settings.llmProvider)))
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(FieldBackground())
            .opacity(0.65)
            .help(String(localized: "transcribe.summary.model.follow.hint"))
        }
    }

    /// 菜单标签通用件（FieldBackground 玻璃底 + 右侧小箭头；mono 切换模型行）。
    private func menuLabel(text: String, mono: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(mono ? Theme.mono(12.5) : .system(size: 12.5))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FieldBackground())
        .contentShape(Rectangle())
    }

    /// 自定义模型 ID 行（下拉选「自定义模型」时出现；custom 端点即模型行本体不重复）。
    private var showsCustomModelIDRow: Bool {
        guard let pinned = provider else { return false }
        return !pinned.modelPresets.isEmpty && usesCustomModel
    }

    private var customModelIDRow: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 58, height: 1)
            VStack(alignment: .leading, spacing: 4) {
                GlassField(
                    "transcribe.summary.model.customid.placeholder",
                    text: $customModelID,
                    invalid: customModelInvalid)
                if customModelInvalid {
                    Text("transcribe.summary.model.customid.empty")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.err)
                }
            }
        }
    }

    // MARK: ② 总结 Prompt 预设（节标签 + 三段分段 + 职能副行）

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("transcribe.summary.preset")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2)
            GlassSegmented(
                options: AppSettings.SummaryPreset.allCases,
                selection: $preset,
                small: true,
                label: { $0.displayName })
            Text(preset.roleDescription)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
        // 切入「自定义」且草稿为空 → 预填默认提示词（TASK-157 追裁：用户逐字稿）；
        // 已有自定义文案不覆盖（含保存过的存量）。
        .onChange(of: preset) { _, new in
            guard new == .custom else { return }
            customDraft = Self.seededCustomDraft(customDraft)
        }
    }

    /// 自定义预设默认提示词（用户 2026-10-26 逐字稿勿修正）：草稿空白、或内容与
    /// 任一内置 Prompt 逐字相同（历史路径把内置文案存进了自定义槽——§78 判据同款
    /// 「≠ 内置文案才算自定义」）时预填；真实自定义文案原样保留不覆盖。
    static func seededCustomDraft(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtin = [
            AppSettings.SummaryPreset.meeting.builtinPrompt,
            AppSettings.SummaryPreset.expert.builtinPrompt,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.isEmpty || builtin.contains(trimmed) {
            return String(localized: "transcribe.summary.preset.customDefault")
        }
        return text
    }

    // MARK: ③ Prompt 内容（内置预设只读展示 / 自定义编辑；风格编辑器 promptField 同款容器）

    /// 内置预设 = 只读文案（2026-10-25 追裁：不允许输入——非文本控件、不可聚焦）；
    /// 自定义 = PlainTextEditor 编辑（§78 全保）。
    @ViewBuilder
    private var promptField: some View {
        if let builtin = preset.builtinPrompt {
            builtinPromptView(builtin)
        } else {
            customPromptEditor
        }
    }

    /// 内置文案只读视图：与编辑器同视觉容器（field 底 190pt + 内滚）。
    private func builtinPromptView(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .lineSpacing(5)
                .foregroundStyle(Theme.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .frame(height: 190)
        .background(FieldBackground())
    }

    private var customPromptEditor: some View {
        ZStack(alignment: .bottomTrailing) {
            PlainTextEditor(text: $customDraft) { focused = $0 }
                .frame(height: 190)
                .background(FieldBackground())
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? Theme.blue : .clear, lineWidth: 1.5))
                .onChange(of: customDraft) { _, newValue in
                    if newValue.count > Self.promptLimit {
                        customDraft = String(newValue.prefix(Self.promptLimit)) // 8000 硬截断
                    }
                }
            if customDraft.isEmpty {
                Text("transcribe.summary.prompt.placeholder")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, PlainTextEditor.insetX + 2)
                    .padding(.vertical, PlainTextEditor.insetY + 1)
                    .allowsHitTesting(false)
            }
            Text("\(customDraft.count) / \(Self.promptLimit)")
                .font(Theme.mono(12))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
    }

    // MARK: 底部（校验提示 + fork 注记 + 三钮）

    private var trimmedCustomEmpty: Bool {
        preset == .custom && customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 自定义模型 ID 缺失：custom 端点（无预设，模型恒手填）或钉选家下拉选了自定义模型。
    private var customModelInvalid: Bool {
        guard let pinned = provider else { return false }
        guard pinned.modelPresets.isEmpty || usesCustomModel else { return false }
        return customModelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var saveDisabled: Bool {
        trimmedCustomEmpty || customModelInvalid
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 校验提示（常驻占位防跳动；二取一显示）
            Text(trimmedCustomEmpty
                ? String(localized: "transcribe.summary.prompt.empty")
                : String(localized: "transcribe.summary.model.customid.empty"))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.err)
                .opacity(saveDisabled ? 1 : 0)
            HStack(spacing: 10) {
                Button("transcribe.summary.prompt.reset") { resetToDefault() }
                    .buttonStyle(.themeGhost)
                    .help(String(localized: "transcribe.summary.prompt.reset.help"))
                Spacer(minLength: 10)
                Button("transcribe.summary.prompt.cancel") { onCancel() }
                    .buttonStyle(.themeGhost)
                Button("transcribe.summary.prompt.save") { save() }
                    .buttonStyle(.themePrimary)
                    .disabled(saveDisabled)
            }
            .padding(.top, 12)
        }
    }

    /// 恢复默认：预设回会议纪要助理 + 服务回跟随全局 + 模型三键复位 + 自定义草稿清空。
    private func resetToDefault() {
        preset = .meeting
        customDraft = ""
        provider = nil
        model = ""
        usesCustomModel = false
        customModelID = ""
    }

    private func followGlobal() {
        provider = nil
        model = ""
        usesCustomModel = false
        customModelID = ""
    }

    /// 钉选瞬间模型快照：取该家「AI 服务」页当前下拉状态（preset/usesCustom/customID）。
    private func pin(_ target: AppSettings.LLMProvider) {
        provider = target
        model = settings.llmModelPreset(for: target)
        usesCustomModel = settings.llmUsesCustomModel(for: target)
        customModelID = settings.llmModelCustomID(for: target)
    }

    private func save() {
        guard !saveDisabled else { return }
        onSave(Draft(
            preset: preset,
            customText: customDraft,
            provider: provider,
            model: model,
            usesCustomModel: usesCustomModel,
            customModelID: customModelID))
    }
}
