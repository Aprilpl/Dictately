import SwiftUI

/// AI 服务设置页（2026-10-02 两级化，定稿原型 docs/design-demos/ai-service-providers.html）：
/// 一级 = 供应商卡列表（七家，卡片语言同听写模型页：名称 + 当前使用/密钥/模型 chips +
/// 描述 + 「使用」小按钮 + ›）；点卡片进二级（StyleListView → StyleEditorView 同款页内替换）。
/// 二级 = 该供应商配置表单：「服务配置」卡（Base URL 预填各家端点 / API Key / 模型预设
/// 下拉 + 自定义模型 ID 分离两行，TASK-096）+ MODEL PARAMETERS 卡（推理思考 / 温度）
/// + 测试连接 + 保存。
/// 「当前使用」只在一级卡「使用」切换（保存不切换服务）；Key 按供应商分存 Keychain；
/// 配置按供应商分键（AppSettings.llm*(for:)），互不覆盖。
/// 同形脚手架（卡片/页头/值列/行件/底栏）与纯逻辑（生效模型/中段省略/Debug 直入）自
/// TASK-117 起在 ProviderSettingsSupport 单一来源；两页知情差异经参数注入。
struct LLMSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// 二级页态：nil = 一级列表（页内整页替换，非导航 push）。
    @State private var selectedProvider: AppSettings.LLMProvider?
    /// 本地镜像（bug00013 铁律：AppSettings 非 Observable，卡片选中态即时刷新靠它）。
    @State private var currentProvider: AppSettings.LLMProvider = .deepseek
    @State private var keyStates: [AppSettings.LLMProvider: Bool] = [:]
    /// 「使用」前置测试进行中的供应商（TASK-120 先测后切；nil = 无在跑测试）。
    @State private var useTestingProvider: AppSettings.LLMProvider?

    var body: some View {
        Group {
            if let provider = selectedProvider {
                LLMProviderDetailView(
                    provider: provider,
                    onBack: { selectedProvider = nil }
                )
            } else {
                providerList
            }
        }
    }

    // MARK: - 一级页 · 供应商列表

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: 9) {
                    ForEach(AppSettings.LLMProvider.allCases, id: \.self) { provider in
                        providerCard(provider)
                    }
                }
                .padding(.top, 24) // 页头→首卡（同旧版首卡 24）

                Text("settings.llm.providers.hint")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(4)
                    .padding(.top, 12)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 48) // TASK-082：顶部 ×3
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            // 从二级页返回时重新刷新（Key/模型可能已保存变更）
            currentProvider = environment.settings.llmProvider
            refreshKeyStates()
            applyDebugDetailArgument()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("settings.llm.title")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("settings.llm.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }

    /// 供应商卡（共享件 ProviderListCard；按钮文案键为本页命名空间，值与 ASR 页相同）。
    private func providerCard(_ provider: AppSettings.LLMProvider) -> some View {
        ProviderListCard(
            name: provider.displayName,
            cardDescription: provider.cardDescription,
            isCurrent: provider == currentProvider,
            hasKey: keyStates[provider] == true,
            modelChip: environment.settings.llmModel(for: provider),
            inUseKey: "settings.llm.inuse",
            useKey: "settings.llm.use",
            useTesting: provider == useTestingProvider,
            useDisabled: useTestingProvider != nil,
            onUse: { use(provider) },
            onOpen: { selectedProvider = provider })
    }

    /// 「使用」切换当前服务（TASK-120 用户裁决：先测后切）——对目标家**已保存**配置
    /// 跑一次真实测试连接（与二级页「测试连接」同链路），通过才切换（本地镜像 +
    /// settings 双写，立即对下一次听写生效）；失败不落任何写入，弹全站 Toast
    /// （灰色 ↻ 固定短文案，与历史页失败 Toast 同语义）。保存语义不受影响
    /// （save 门禁从不看测试结果，AGENTS §41）。
    /// 「使用中」显示门槛 = 当前且已配 Key（§41 追裁）——未配 Key 的当前家按钮照常
    /// 显示「使用」，点击走同一测试链路（通过即回使用中态），故不设 current 排除。
    private func use(_ provider: AppSettings.LLMProvider) {
        guard useTestingProvider == nil else { return }
        guard let config = ProviderSettingsSupport.savedLLMConfig(
            provider: provider,
            settings: environment.settings,
            secrets: environment.secrets) else {
            environment.toast.show(ProviderSettingsSupport.useBlockedToastText, info: true)
            return
        }
        useTestingProvider = provider
        let engine = environment.llmEngine

        Task.detached {
            let ok = (try? await engine.testConnection(config: config)) != nil
            if ok {
                AppLog.pipeline.info("llm use probe ok provider=\(provider.rawValue, privacy: .public)")
            } else {
                AppLog.pipeline.error("llm use probe failed provider=\(provider.rawValue, privacy: .public)")
            }
            await MainActor.run {
                useTestingProvider = nil
                if ok {
                    currentProvider = provider
                    environment.settings.llmProvider = provider
                    // 探测通过意味着 Key 实际在位——刷新 chips，防 keyStates 陈旧时
                    // 使用中门槛（当前且已配 Key）把卡片误留在「使用」。
                    refreshKeyStates()
                } else {
                    environment.toast.show(ProviderSettingsSupport.useBlockedToastText, info: true)
                }
            }
        }
    }

    private func refreshKeyStates() {
        keyStates = ProviderSettingsSupport.keyStates(
            providers: AppSettings.LLMProvider.allCases,
            account: SecretAccount.llmAccount(for:),
            secrets: environment.secrets)
    }

    /// Debug 自动化：`--llm-detail` 直接进入当前供应商的二级页（截图/走查脚本用，
    /// 与 `--style-editor` 同款机制；仅 Debug 编译进二进制）。
    private func applyDebugDetailArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--llm-detail") else { return }
        selectedProvider = environment.settings.llmProvider
        #endif
    }
}

/// 二级页 · 单供应商配置表单（沿用旧 AI 服务页表单骨架，字段改按 provider 分键；
/// 表单三层限宽同款：800 列 / 22 内距 / 顶 42（StyleEditor 二级页标准））。
struct LLMProviderDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let provider: AppSettings.LLMProvider
    let onBack: () -> Void

    private typealias TestState = ProviderSettingsSupport.TestState

    @State private var keyConfigured = false
    @State private var baseURLInput = ""
    @State private var presetModel = ""
    /// 下拉是否选「自定义模型」（TASK-096 分离交互；custom 端点无预设不走此态）。
    @State private var usesCustomModel = false
    @State private var customModelInput = ""
    @State private var temperatureInput = ""
    @State private var reasoningEffort = "" // ""=关闭 | low（2026-10-04：开启即最低档，中/高退役）
    @State private var testState: TestState = .idle
    @State private var savedFlash = false
    @State private var savedFlashTask: Task<Void, Never>?
    @State private var isCurrent = false

    private var urlOK: Bool { provider.baseURLIsValid(baseURLInput) }

    /// 模型校验（TASK-096 用户裁决）：预设供应商选了「自定义模型」时 ID 必填；
    /// custom 端点（无预设）恒过（留空 = 不携带 model，行为同旧版）。
    private var modelOK: Bool {
        provider.modelPresets.isEmpty || !usesCustomModel
            || !customModelInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var temperatureOK: Bool {
        let text = temperatureInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        guard let value = Double(text) else { return false }
        return (0...1).contains(value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProviderDetailBackButton(titleKey: "settings.llm.back", action: onBack)
                ProviderDetailTitleRow(
                    name: provider.displayName, isCurrent: isCurrent, keyConfigured: keyConfigured)

                ProviderSectionLabel(key: "settings.llm.section.service", first: true)

                SettingsCard {
                    baseURLRow
                    keyRow
                    modelRow
                    if !provider.modelPresets.isEmpty {
                        customModelIDRow
                    }
                }

                ProviderSectionLabel(key: "settings.llm.section.params", first: false)

                SettingsCard {
                    reasoningRow
                    temperatureRow
                }

                bottomBar

                Text(detailHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(4)
                    .padding(.top, 12)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 42) // 二级页标准（StyleEditor 同款）
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
    }

    // MARK: - 服务配置卡（共享行件；本页参数注入）

    /// Base URL（各家端点预填 + 端点提示；hint 动态取自 LLMProviderCatalog，非法时红字——
    /// custom 的 http 放行文案与官方服务不同，且与 ASR 页措辞有知情差异勿统一）。
    private var baseURLRow: some View {
        ProviderBaseURLRow(
            urlOK: urlOK,
            hint: urlOK ? provider.baseURLHint : invalidURLHint,
            placeholder: "https://your-service.com/v1",
            text: $baseURLInput)
    }

    /// 非法提示按 provider 区分：custom（http 放行）与官方服务（https-only）文案不同。
    private var invalidURLHint: String {
        provider.allowsPlainHTTP
            ? String(localized: "settings.llm.baseurl.invalid.custom")
            : String(localized: "settings.llm.baseurl.invalid")
    }

    /// Debug 起始态门控：load()（含 keyConfigured 读出）完成后才置值传给组件。
    @State private var keyDebugStart: APIKeyField.DebugStart = .none

    /// API Key 三态字段（2026-10-03 原型定稿）：交互全在 APIKeyField/共享行件内；
    /// 本页只接 isConfigured 镜像 + 提交落盘（+10 chip 右移语义见共享件注释）。
    private var keyRow: some View {
        ProviderKeyRow(
            titleKey: "settings.llm.apikey",
            hintKey: "settings.llm.apikey.hint",
            isConfigured: keyConfigured,
            debugStart: keyDebugStart,
            keyPageURL: provider.apiKeyURL,
            onCommit: commitAPIKey)
    }

    /// 模型行（TASK-096 分离交互；行标题/hint/placeholder 为本页文案键）。
    private var modelRow: some View {
        ProviderModelRow(
            presets: provider.modelPresets,
            customTitle: String(localized: "settings.llm.model"),
            customHint: String(localized: "settings.llm.model.custom.hint"),
            customPlaceholder: "glm-4.7-flash",
            presetTitle: String(localized: "settings.llm.model"),
            presetHint: String(localized: "settings.llm.model.hint"),
            customOptionText: String(localized: "settings.llm.model.custom"),
            customModelInput: $customModelInput,
            presetModel: $presetModel,
            usesCustomModel: $usesCustomModel)
    }

    /// 自定义模型 ID 行（TASK-096 用户裁决：与下拉分离 + 禁用态常驻，详见共享件注释）。
    private var customModelIDRow: some View {
        ProviderCustomModelIDRow(
            title: String(localized: "settings.llm.model.customid"),
            hint: String(localized: "settings.llm.model.customid.hint"),
            emptyKey: "settings.llm.model.customid.empty",
            placeholder: "glm-4.7-flash",
            modelOK: modelOK,
            usesCustomModel: usesCustomModel,
            customModelInput: $customModelInput)
    }

    // MARK: - MODEL PARAMETERS 卡

    /// 表单当前生效模型（与 save()/runTestConnection 同源计算；供思考锁关判定）。
    private var effectiveModelID: String {
        ProviderSettingsSupport.effectiveModel(
            hasPresets: !provider.modelPresets.isEmpty,
            preset: presetModel,
            usesCustom: usesCustomModel,
            customID: customModelInput)
    }

    /// 百炼托管 DeepSeek-V4 系：思考开启仅支持流式、App 恒非流式 →「低」不可选
    /// （ThinkingPolicy 对遗留 "low" 存量同款兜底发关闭参数，UI 与请求两侧一致）。
    private var reasoningLockedOff: Bool {
        provider == .bailian && effectiveModelID.lowercased().contains("deepseek")
    }

    /// 推理思考（2026-10-04 裁决：关闭/低两态——关闭经 ThinkingPolicy 按供应商
    /// 分派出真正生效的关闭参数，非「省略」；开启 = 各家最低档）。hint 按供应商
    /// 动态（沿 baseURLRow 的 String 先例），锁关与模型边界随页说明。
    private var reasoningRow: some View {
        SettingRow(title: String(localized: "settings.llm.reasoning"), hint: reasoningHint) {
            providerValueColumn(reasoningMenu.padding(.leading, 8))
        }
    }

    /// 逐家 hint：默认「默认关闭；开启即最低档」；智谱 5.3 系思考常开无法关闭、
    /// OpenCode 端点未定义思考参数、百炼托管 deepseek 非流式不可开启。
    private var reasoningHint: String {
        if reasoningLockedOff {
            return String(localized: "settings.llm.reasoning.hint.locked")
        }
        switch provider {
        case .zhipu where effectiveModelID.lowercased().hasPrefix("glm-5.3"):
            return String(localized: "settings.llm.reasoning.hint.zhipu")
        case .opencode:
            return String(localized: "settings.llm.reasoning.hint.opencode")
        default:
            return String(localized: "settings.llm.reasoning.hint")
        }
    }

    private var reasoningMenu: some View {
        Menu {
            Button("settings.llm.reasoning.off") { reasoningEffort = "" }
            Button("settings.llm.reasoning.low") { reasoningEffort = "low" }
                .disabled(reasoningLockedOff)
        } label: {
            HStack(spacing: 8) {
                Text(reasoningLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: 110, alignment: .leading)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var reasoningLabel: String {
        guard reasoningEffort == "low", !reasoningLockedOff else {
            return String(localized: "settings.llm.reasoning.off")
        }
        return String(localized: "settings.llm.reasoning.low")
    }

    /// 温度（0–1；空 = 默认 0.7 由 placeholder 承担，非法时后缀「需为 0–1」）。
    private var temperatureRow: some View {
        SettingRow("settings.llm.temperature", hint: "settings.llm.temperature.hint", divider: false) {
            providerValueColumn(
                HStack(spacing: 8) {
                    GlassField(
                        "settings.llm.temperature.default", text: $temperatureInput,
                        width: 80, invalid: !temperatureOK)
                    suffixLabel
                })
        }
    }

    private var suffixLabel: some View {
        let text = temperatureInput.trimmingCharacters(in: .whitespaces)
        return Group {
            if !text.isEmpty && !temperatureOK {
                Text("settings.llm.temperature.invalid")
                    .foregroundStyle(Theme.warn)
            }
        }
        .font(.system(size: 12))
    }

    /// 底部动作条（共享件）：保存禁用比 ASR 页多 temperatureOK（本页特有参数卡）。
    private var bottomBar: some View {
        ProviderDetailBottomBar(
            testDisabled: testState == .testing || !urlOK || !modelOK,
            saveDisabled: !urlOK || !temperatureOK || !modelOK,
            testState: testState,
            savedFlash: $savedFlash,
            saveKey: "settings.llm.save",
            savedKey: "settings.llm.saved",
            onTest: runTestConnection,
            onSave: save)
    }

    private var detailHint: String {
        String(format: String(localized: "settings.llm.detail.hint"), provider.displayName)
    }

    // MARK: - 保存 / 校验 / Keychain / 测试

    private func load() {
        // 「当前使用」chip 门槛与一级卡使用中一致：当前供应商且已配 Key（§41 追裁）。
        let account = SecretAccount.llmAccount(for: provider)
        keyConfigured = ((try? environment.secrets.get(account)) ?? "")?.isEmpty == false
        isCurrent = environment.settings.llmProvider == provider && keyConfigured
        baseURLInput = environment.settings.llmBaseURL(for: provider)
        presetModel = environment.settings.llmModelPreset(for: provider)
        usesCustomModel = environment.settings.llmUsesCustomModel(for: provider)
        customModelInput = environment.settings.llmModelCustomID(for: provider)
        temperatureInput = environment.settings.llmTemperatureText(for: provider)
        reasoningEffort = environment.settings.llmReasoningEffort(for: provider)
        // Debug 起始态在镜像就绪后才放行（组件 onChange 响应）
        if keyDebugStart == .none { keyDebugStart = ProviderSettingsSupport.debugKeyStart }
    }

    /// FR-007：scheme 校验按 provider（官方服务 https-only；custom 放行 http，
    /// 判定集中在 LLMProvider.baseURLIsValid——2026-10-02 用户裁决本地网关可用）。

    /// 全字段落盘（本供应商分键）+ 成功闪「✓ 已保存」。
    /// Key 不在此列：三态字段全权接管其生命周期（常驻输入框退役后「顺带存非空 Key」失去存在理由）。
    private func save() {
        guard urlOK, temperatureOK, modelOK else { return }
        environment.settings.setLLMBaseURL(
            baseURLInput.trimmingCharacters(in: .whitespaces), for: provider)
        // 生效模型 = 按分离规则算好写 llm.model.<provider>（live()/一级卡 chip 读它）；
        // 同时落三个 UI 状态键（preset/usesCustom/customID），下次进页回显一致。
        environment.settings.setLLMModel(
            ProviderSettingsSupport.effectiveModel(
                hasPresets: !provider.modelPresets.isEmpty,
                preset: presetModel,
                usesCustom: usesCustomModel,
                customID: customModelInput),
            for: provider)
        environment.settings.setLLMModelCustomID(
            customModelInput.trimmingCharacters(in: .whitespaces), for: provider)
        if !provider.modelPresets.isEmpty {
            environment.settings.setLLMModelPreset(presetModel, for: provider)
            environment.settings.setLLMUsesCustomModel(usesCustomModel, for: provider)
        }
        environment.settings.setLLMTemperatureText(
            temperatureInput.trimmingCharacters(in: .whitespaces), for: provider)
        environment.settings.setLLMReasoningEffort(reasoningEffort, for: provider)
        testState = .idle
        savedFlash = true
        savedFlashTask?.cancel()
        savedFlashTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { savedFlash = false }
        }
    }

    /// APIKeyField 提交（空=清除该账户 Key，非空=保存；掩码串已被状态机拦截不会到达）。
    /// 落盘走共享件（账户 = SecretAccount.llmAccount(for:)）；成功才刷新 chip 镜像。
    private func commitAPIKey(_ value: String) {
        if ProviderSettingsSupport.commitAPIKey(
            value,
            account: SecretAccount.llmAccount(for: provider),
            secrets: environment.secrets) {
            keyConfigured = !value.isEmpty
            // Key 增删即时联动「当前使用」chip（门槛 = 当前且已配 Key，§41 追裁）
            isCurrent = environment.settings.llmProvider == provider && keyConfigured
            testState = .idle
        }
    }

    /// 测试连接（契约 B ping + max_tokens 1）；先落当前合法输入，保证测的是所填配置。
    /// 注意 config 直接按本供应商表单组装（live() 读「当前供应商」——编辑非当前家时会错）。
    private func runTestConnection() {
        guard testState != .testing, urlOK, modelOK else { return }
        save()
        testState = .testing

        let model = ProviderSettingsSupport.effectiveModel(
            hasPresets: !provider.modelPresets.isEmpty,
            preset: presetModel,
            usesCustom: usesCustomModel,
            customID: customModelInput)
        let config = LLMConfig(
            baseURL: URL(string: baseURLInput.trimmingCharacters(in: .whitespaces))
                ?? URL(string: "https://api.deepseek.com")!,
            apiKey: (try? environment.secrets.get(SecretAccount.llmAccount(for: provider))) ?? "",
            model: model,
            temperature: environment.settings.llmTemperatureValue(for: provider),
            thinkingParams: ThinkingPolicy.params(
                provider: provider,
                model: model,
                effortLow: reasoningEffort == AppSettings.LLMReasoningEffort.low.rawValue),
            opencodeSessionID: environment.settings.opencodeSessionID)
        let engine = environment.llmEngine

        Task.detached {
            let outcome: TestState
            do {
                let latency = try await engine.testConnection(config: config)
                AppLog.pipeline.info("llm test connection ok provider=\(provider.rawValue, privacy: .public) latency=\(latency)ms")
                outcome = .success(String(format: String(localized: "settings.asr.test.success", bundle: AppResources.bundle), latency))
            } catch let error as LLMError {
                // 带状态码/body 摘要（badRequest 等不透明 4xx 无日志也能自诊）
                outcome = .failure(error.diagnosticMessage)
            } catch {
                outcome = .failure(String(describing: error))
            }
            await MainActor.run { testState = outcome }
        }
    }
}
