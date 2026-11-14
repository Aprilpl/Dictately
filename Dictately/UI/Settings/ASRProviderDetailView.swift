import SwiftUI

struct ASRProviderDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let provider: AppSettings.ASRProvider
    let onBack: () -> Void

    private typealias TestState = ProviderSettingsSupport.TestState

    /// 即时热词行（UI 保序；持久化为 [String: Int]）。
    private struct HotwordRow: Identifiable {
        let id = UUID()
        var word: String
        var weight: Int
    }

    /// 语言提示可选项（代码与显示名经 AppSettings.languageOptionLabel 统一）。
    static let languageCodes = ["zh", "en", "yue", "ja"]

    @State private var keyConfigured = false
    @State private var baseURLInput = ""
    @State private var presetModel = ""
    /// 下拉是否选「自定义模型」（TASK-098 分离交互；custom 端点无预设不走此态）。
    @State private var usesCustomModel = false
    @State private var customModelInput = ""
    /// 听写参数（全局键、即改即生效；镜像驱动重绘——bug00013 铁律）。
    @State private var languageHints: [String] = []
    @State private var hotwordRows: [HotwordRow] = []
    @State private var testState: TestState = .idle
    @State private var savedFlash = false
    @State private var savedFlashTask: Task<Void, Never>?
    @State private var isCurrent = false

    private var urlOK: Bool { provider.baseURLIsValid(baseURLInput) }

    /// 模型校验（TASK-098 用户裁决同款）：预设供应商选了「自定义模型」时 ID 必填；
    /// custom 端点（无预设）恒过（留空 = 不携带 model，行为同旧版）。
    private var modelOK: Bool {
        provider.modelPresets.isEmpty || !usesCustomModel
            || !customModelInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProviderDetailBackButton(titleKey: "models.back", action: onBack)
                ProviderDetailTitleRow(
                    name: provider.displayName, isCurrent: isCurrent, keyConfigured: keyConfigured)

                ProviderSectionLabel(key: "models.section.service", first: true)

                SettingsCard {
                    baseURLRow
                    keyRow
                    modelRow
                    if !provider.modelPresets.isEmpty {
                        customModelIDRow
                    }
                }

                ProviderSectionLabel(key: "models.section.params", first: false)

                SettingsCard {
                    paramsCardRows
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

    /// Base URL（五家都可编辑——openai/groq/mistral 预填官方端点、custom 手填；
    /// hint 动态取自 ASRProviderCatalog，非法时红字——custom 的 http 放行文案不同，
    /// 且与 AI 服务页措辞有知情差异勿统一）。
    private var baseURLRow: some View {
        ProviderBaseURLRow(
            urlOK: urlOK,
            hint: urlOK ? provider.baseURLHint : invalidURLHint,
            placeholder: "https://your-asr-service.com/v1",
            text: $baseURLInput)
    }

    /// 非法提示按 provider 区分：custom（http 放行）与官方服务（https-only）文案不同。
    private var invalidURLHint: String {
        provider.allowsPlainHTTP
            ? String(localized: "models.baseurl.invalid.custom")
            : String(localized: "models.baseurl.invalid")
    }

    /// Debug 起始态门控：load()（含 keyConfigured 读出）完成后才置值传给组件。
    @State private var keyDebugStart: APIKeyField.DebugStart = .none

    /// API Key 三态字段（2026-10-03 原型定稿）：交互全在 APIKeyField/共享行件内；
    /// 本页只接 isConfigured 镜像 + 提交落盘（+10 chip 右移语义见共享件注释）。
    private var keyRow: some View {
        ProviderKeyRow(
            titleKey: "models.apikey",
            hintKey: "models.apikey.hint",
            isConfigured: keyConfigured,
            debugStart: keyDebugStart,
            keyPageURL: provider.apiKeyURL,
            onCommit: commitAPIKey)
    }

    /// 模型字段 placeholder（TASK-128 追裁：按家区分——四家有预设的供应商显各自
    /// 默认模型 ID，不再全站共用同一个 qwen 家 ID；custom 端点无已知各家模型，
    /// 回落通用文案键。与 LLM 页 modelIDPlaceholder 同构）。
    private var modelIDPlaceholder: LocalizedStringKey {
        provider.defaultModel.isEmpty
            ? "models.model.id.placeholder"
            : LocalizedStringKey(provider.defaultModel)
    }

    /// 模型行（TASK-098 分离交互；行标题/hint/placeholder 为本页文案——custom 端点
    /// 「模型名」沿用旧文案，与 LLM 页「模型」有知情差异勿统一）。
    private var modelRow: some View {
        ProviderModelRow(
            presets: provider.modelPresets,
            customTitle: String(localized: "models.model"),
            customHint: String(localized: "models.model.custom.hint"),
            customPlaceholder: modelIDPlaceholder,
            presetTitle: String(localized: "models.model.title"),
            presetHint: String(localized: "models.model.hint"),
            customOptionText: String(localized: "models.model.custom"),
            customModelInput: $customModelInput,
            presetModel: $presetModel,
            usesCustomModel: $usesCustomModel)
    }

    /// 自定义模型 ID 行（TASK-098 用户裁决：与下拉分离 + 禁用态常驻，详见共享件注释）。
    private var customModelIDRow: some View {
        ProviderCustomModelIDRow(
            title: String(localized: "models.model.customid"),
            hint: String(localized: "models.model.customid.hint"),
            emptyKey: "models.model.customid.empty",
            placeholder: modelIDPlaceholder,
            modelOK: modelOK,
            usesCustomModel: usesCustomModel,
            customModelInput: $customModelInput)
    }

    // MARK: - 听写参数卡（按能力矩阵；语言/热词用 stack 行满宽，方言标准行）

    /// 行序：语言提示 → 即时热词 → 方言保留；无任何能力 → 一行说明（原 capsNoneNote）。
    @ViewBuilder private var paramsCardRows: some View {
        if provider.supportsLanguageHints {
            languageRow(divider: provider.supportsHotwords || provider.supportsDialect)
        }
        if provider.supportsHotwords {
            hotwordRow(divider: provider.supportsDialect)
        }
        if provider.supportsDialect {
            SettingRow("models.dialect", divider: false) {
                GlassToggle(isOn: dialectBinding, label: String(localized: "models.dialect"))
            }
        }
        if !provider.supportsLanguageHints && !provider.supportsHotwords && !provider.supportsDialect {
            capsNoneNote
        }
    }

    /// 语言提示 chips（最多 4 项；qwen 按顺序作 language_hints，兼容系作 prompt 前缀）。
    private func languageRow(divider: Bool) -> some View {
        SettingStackRow("models.langs", hint: languageHint, divider: divider) {
            HStack(spacing: 7) {
                ForEach(Self.languageCodes, id: \.self) { code in
                    languageChip(code)
                }
                Spacer()
            }
        }
    }

    private var languageHint: LocalizedStringKey {
        provider == .qwen ? "models.langs.hint.qwen" : "models.langs.hint.compat"
    }
    private func languageChip(_ code: String) -> some View {
        let on = languageHints.contains(code)
        return Button {
            toggleLanguage(code)
            testState = .idle
        } label: {
            Text((on ? "✓ " : "") + (AppSettings.languageOptionLabel(for: code) ?? code))
                .font(.system(size: 12.5))
                .foregroundStyle(on ? Theme.text1 : Theme.text2)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.blueTintBg : Theme.fillSoft))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.blueTintBorder : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 语言提示开关：最多 4 项（可选项总数即 4，天然不超）；本地态 + settings 双写。
    private func toggleLanguage(_ code: String) {
        if languageHints.contains(code) {
            languageHints.removeAll { $0 == code }
        } else {
            languageHints.append(code)
        }
        environment.settings.languageHints = languageHints
    }

    /// 即时热词表格（v2-glass：词/权重表头 + 行内编辑 + 权重下拉 + × 删除 + 添加热词）。
    private func hotwordRow(divider: Bool) -> some View {
        SettingStackRow("models.hotwords", hint: "models.hotwords.hint", divider: divider) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("models.hotwords.col.word")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text("models.hotwords.col.weight")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 76, alignment: .leading)
                    Color.clear.frame(width: 24)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.fillSoft)

                ForEach(hotwordRows) { row in
                    hotwordLine(row)
                }

                HStack {
                    Button("models.hotwords.add") { addHotword() }
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                        .disabled(hotwordRows.count >= 50)
                    Spacer()
                    if hotwordRows.count >= 50 {
                        Text("models.hotwords.limit")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 4)
        }
    }
    private func hotwordLine(_ row: HotwordRow) -> some View {
        HStack(spacing: 8) {
            TextField("models.hotwords.placeholder", text: hotwordWordBinding(row.id))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Spacer()
            weightMenu(row.id)
            Button {
                removeHotword(row.id)
            } label: {
                Text("×")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
    private func weightMenu(_ id: UUID) -> some View {
        Menu {
            ForEach(1...5, id: \.self) { n in
                Button("\(n)") { setHotwordWeight(id, n) }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(hotwordRows.first { $0.id == id }?.weight ?? 1)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: 76, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func hotwordWordBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { hotwordRows.first { $0.id == id }?.word ?? "" },
            set: {
                if let index = hotwordRows.firstIndex(where: { $0.id == id }) {
                    hotwordRows[index].word = $0
                    persistHotwords()
                }
            })
    }

    private func setHotwordWeight(_ id: UUID, _ weight: Int) {
        if let index = hotwordRows.firstIndex(where: { $0.id == id }) {
            hotwordRows[index].weight = weight
            persistHotwords()
        }
    }

    private func addHotword() {
        hotwordRows.append(HotwordRow(word: "", weight: 1))
    }

    private func removeHotword(_ id: UUID) {
        hotwordRows.removeAll { $0.id == id }
        persistHotwords()
    }

    /// UI 行 → settings.asrVocabulary（空词行不落库；重名词后者覆盖；≤50 条）。
    private func persistHotwords() {
        var vocabulary: [String: Int] = [:]
        for row in hotwordRows {
            let word = row.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            vocabulary[word] = row.weight
        }
        environment.settings.asrVocabulary = vocabulary
    }

    private var dialectBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.keepDialect },
            set: { environment.settings.keepDialect = $0 })
    }

    /// 非热词/方言能力服务商的说明行（v2-glass caps 空时提示，逐字文案）。
    private var capsNoneNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Chip(text: "ℹ", tone: .neutral)
            Text("models.caps.none")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - 底部动作条（共享件；无温度门禁——本页无 MODEL PARAMETERS 卡）

    private var bottomBar: some View {
        ProviderDetailBottomBar(
            testDisabled: testState == .testing || !urlOK || !modelOK,
            saveDisabled: !urlOK || !modelOK,
            testState: testState,
            savedFlash: $savedFlash,
            saveKey: "models.save",
            savedKey: "models.saved",
            onTest: runTestConnection,
            onSave: save)
    }

    private var detailHint: String {
        String(format: String(localized: "models.detail.hint"), provider.displayName)
    }

    // MARK: - 载入 / 保存 / Keychain / 测试

    private func load() {
        // 「当前使用」chip 门槛与一级卡使用中一致：当前供应商且已配 Key（§41 追裁）
        // **且引擎走 API**（2026-10-11 互斥修复：本地模型使用中时 API 不显使用中）。
        let account = SecretAccount.asrAccount(for: provider)
        keyConfigured = ((try? environment.secrets.get(account)) ?? "")?.isEmpty == false
        isCurrent = environment.settings.asrProvider == provider
            && keyConfigured
            && environment.settings.asrMode == .api
        baseURLInput = environment.settings.asrBaseURL(for: provider)
        presetModel = environment.settings.asrModelPreset(for: provider)
        usesCustomModel = environment.settings.asrUsesCustomModel(for: provider)
        customModelInput = environment.settings.asrModelCustomID(for: provider)
        languageHints = environment.settings.languageHints
        hotwordRows = environment.settings.asrVocabulary
            .sorted { $0.key < $1.key }
            .map { HotwordRow(word: $0.key, weight: $0.value) }
        // Debug 起始态在镜像就绪后才放行（组件 onChange 响应）
        if keyDebugStart == .none { keyDebugStart = ProviderSettingsSupport.debugKeyStart }
    }

    /// 全字段落盘（本供应商分键）+ 成功闪「✓ 已保存」。
    /// Key 不在此列：三态字段全权接管其生命周期。语言/热词/方言即改即生效，也不在此列。
    /// 保存不切换当前听写服务（切换语义集中在一级卡「使用」按钮，LLM 同款裁决）。
    private func save() {
        guard urlOK, modelOK else { return }
        environment.settings.setASRBaseURL(
            baseURLInput.trimmingCharacters(in: .whitespaces), for: provider)
        // 生效模型 = 按分离规则算好写 asr.model.<provider>（live()/一级卡 chip 读它）；
        // 同时落三个 UI 状态键（preset/usesCustom/customID），下次进页回显一致。
        environment.settings.setASRModel(
            ProviderSettingsSupport.effectiveModel(
                hasPresets: !provider.modelPresets.isEmpty,
                preset: presetModel,
                usesCustom: usesCustomModel,
                customID: customModelInput),
            for: provider)
        environment.settings.setASRModelCustomID(
            customModelInput.trimmingCharacters(in: .whitespaces), for: provider)
        if !provider.modelPresets.isEmpty {
            environment.settings.setASRModelPreset(presetModel, for: provider)
            environment.settings.setASRUsesCustomModel(usesCustomModel, for: provider)
        }
        testState = .idle
        savedFlash = true
        savedFlashTask?.cancel()
        savedFlashTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { savedFlash = false }
        }
    }

    /// APIKeyField 提交（空=清除该账户 Key，非空=保存；掩码串已被状态机拦截不会到达）。
    /// 落盘走共享件（账户 = SecretAccount.asrAccount(for:)）；成功才刷新 chip 镜像。
    private func commitAPIKey(_ value: String) {
        if ProviderSettingsSupport.commitAPIKey(
            value,
            account: SecretAccount.asrAccount(for: provider),
            secrets: environment.secrets) {
            keyConfigured = !value.isEmpty
            // Key 增删即时联动「当前使用」chip（门槛 = 当前且已配 Key 且引擎走 API）
            isCurrent = environment.settings.asrProvider == provider
                && keyConfigured
                && environment.settings.asrMode == .api
            testState = .idle
        }
    }

    /// 测试连接（内置 MP3 探针）；先落当前合法输入，保证测的是所填配置。
    /// config 直接按本供应商表单组装（live() 读「当前供应商」——编辑非当前家时会
    /// 读错供应商，LLM 页同款警训）。
    private func runTestConnection() {
        guard testState != .testing, urlOK, modelOK else { return }
        save()
        testState = .testing

        let config = ASRConfig(
            provider: provider,
            baseURL: URL(string: baseURLInput.trimmingCharacters(in: .whitespaces))
                ?? URL(string: "https://maas.qianwenaiapi.com")!,
            apiKey: (try? environment.secrets.get(SecretAccount.asrAccount(for: provider))) ?? "",
            model: ProviderSettingsSupport.effectiveModel(
                hasPresets: !provider.modelPresets.isEmpty,
                preset: presetModel,
                usesCustom: usesCustomModel,
                customID: customModelInput),
            audioFormat: .mp3, // 探测负载为 MP3；契约 A 要求 MIME/format 与实际音频一致
            languageHints: environment.settings.languageHints,
            vocabulary: environment.settings.asrVocabulary,
            keepDialect: environment.settings.keepDialect)
        // 探针直走 API 引擎（同 use()：绕过模式路由，本地模式下也测目标供应商）
        let engine = environment.apiASREngine

        Task.detached {
            let outcome: TestState
            do {
                let probe = try TestProbeAudio.bundledURL()
                let result = try await engine.transcribe(audioFileAt: probe, config: config)
                AppLog.pipeline.info("asr test connection ok provider=\(config.provider.rawValue, privacy: .public) latency=\(result.latencyMs)ms")
                outcome = .success(String(format: String(localized: "settings.asr.test.success"), result.latencyMs))
            } catch let error as ASRError {
                // 兜底：若负载被判无语音（emptyResult）仍视为链路通（服务应答正常）
                if error == ASRError.emptyResult {
                    AppLog.pipeline.info("asr test connection ok (no words) provider=\(config.provider.rawValue, privacy: .public)")
                    outcome = .success(String(localized: "settings.asr.test.reached"))
                } else {
                    outcome = .failure(String(format: String(localized: "settings.asr.test.failed"), error.userMessage))
                }
            } catch {
                outcome = .failure(String(format: String(localized: "settings.asr.test.failed"), String(describing: error)))
            }
            await MainActor.run { testState = outcome }
        }
    }
}
