import SwiftUI

/// 听写模型设置页（2026-10-06 两级化，定稿原型 docs/design-demos/ai-service-providers.html，
/// 对齐 AI 服务页 TASK-091 模式）：
/// 一级 = API/本地模型分段 + 五张供应商卡（名称 + 当前使用/密钥/模型 chips + 描述 +
/// 「使用」小按钮 + ›）；点卡片本体进二级（页内整页替换，StyleList→StyleEditor 先例）。
/// 二级 = 该供应商配置表单：「服务配置」卡（Base URL 五家可编辑 / API Key 三态 /
/// 模型预设下拉 + 自定义模型 ID 分离，TASK-098 同款）+「听写参数」卡按能力矩阵
/// （语言提示 / 即时热词 / 方言保留，无能力者显说明行）+ 测试连接 + 保存。
/// 「当前使用」只在一级卡「使用」切换（保存不切换服务）；Key 按供应商分存 Keychain；
/// 配置按供应商分键（AppSettings.asr*(for:)），互不覆盖。
/// 语言提示/热词/方言为全局参数（语义上仅当前听写服务商消费），即改即生效不经「保存」。
/// 同形脚手架与纯逻辑自 TASK-117 起在 ProviderSettingsSupport 单一来源（本页特有的
/// API/本地分段与听写参数卡留在本文件）。
struct ASRSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// 二级页态：nil = 一级列表（页内整页替换，非导航 push）。
    @State private var selectedProvider: AppSettings.ASRProvider?
    /// 本地镜像（bug00013 铁律：AppSettings 非 Observable，卡片选中态即时刷新靠它）。
    @State private var currentProvider: AppSettings.ASRProvider = .qwen
    @State private var keyStates: [AppSettings.ASRProvider: Bool] = [:]
    @State private var asrMode = "api" // api | local
    /// 「使用」前置测试进行中的供应商（TASK-120 先测后切；nil = 无在跑测试）。
    @State private var useTestingProvider: AppSettings.ASRProvider?

    var body: some View {
        Group {
            if let provider = selectedProvider {
                ASRProviderDetailView(
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
                modeSegment
                    .padding(.top, 24) // TASK-082：页头→首控件间距
                    .padding(.bottom, 8)

                if asrMode == "local" {
                    localUnavailableNote
                } else {
                    VStack(spacing: 9) {
                        ForEach(AppSettings.ASRProvider.allCases, id: \.self) { provider in
                            providerCard(provider)
                        }
                    }
                    .padding(.top, 4)

                    Text("models.providers.hint")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(4)
                        .padding(.top, 12)
                }
            }
            // TASK-077/080：三层居中限宽（max 800 / 水平 22 / 顶 48 / 底 16）
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 48) // TASK-082：顶部 ×3
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            // 从二级页返回时重新刷新（Key/模型可能已保存变更）
            currentProvider = environment.settings.asrProvider
            refreshKeyStates()
            applyDebugDetailArgument()
            applyDebugUseProbeArgument()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) { // TASK-082：标题↔副标题 3→6
            Text("models.title")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("models.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }

    /// 本地模型 / API 二级分段（v2-glass Segmented 全尺寸）。本地模型 v1 不做
    /// （PRD 铁律：不做假下载/假开关 UI，仅显说明）。
    private var modeSegment: some View {
        GlassSegmented(
            options: ["api", "local"],
            selection: $asrMode,
            label: { $0 == "api" ? String(localized: "models.mode.api") : String(localized: "models.mode.local") }
        )
    }

    /// 本地模型不可用说明（PRD：v1 不做本地转写模型，引擎协议已预留——不做假下载卡）。
    private var localUnavailableNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("ℹ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text3)
            Text("models.local.unavailable")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(5)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.fillSoft))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.top, 6)
    }

    /// 供应商卡（共享件 ProviderListCard；按钮文案键为本页命名空间，值与 AI 服务页相同）。
    private func providerCard(_ provider: AppSettings.ASRProvider) -> some View {
        ProviderListCard(
            name: provider.displayName,
            cardDescription: provider.cardDescription,
            isCurrent: provider == currentProvider,
            hasKey: keyStates[provider] == true,
            modelChip: environment.settings.asrModel(for: provider),
            inUseKey: "models.inuse",
            useKey: "models.use",
            useTesting: provider == useTestingProvider,
            useDisabled: useTestingProvider != nil,
            onUse: { use(provider) },
            onOpen: { selectedProvider = provider })
    }

    /// 「使用」切换当前听写服务（TASK-120 用户裁决：先测后切）——对目标家**已保存**
    /// 配置跑一次内置 MP3 探针转写（与二级页「测试连接」同链路，emptyResult 仍视为
    /// 链路通），通过才切换（本地镜像 + settings 双写，立即对下一次听写生效）；失败
    /// 不落任何写入，弹全站 Toast（灰色 ↻ 固定短文案）。保存语义不受影响（AGENTS §41）。
    /// 「使用中」显示门槛 = 当前且已配 Key（§41 追裁）——未配 Key 的当前家按钮照常
    /// 显示「使用」，点击走同一测试链路（通过即回使用中态），故不设 current 排除。
    private func use(_ provider: AppSettings.ASRProvider) {
        guard useTestingProvider == nil else { return }
        guard let config = ProviderSettingsSupport.savedASRConfig(
            provider: provider,
            settings: environment.settings,
            secrets: environment.secrets) else {
            environment.toast.show(ProviderSettingsSupport.useBlockedToastText, info: true)
            return
        }
        useTestingProvider = provider
        let engine = environment.asrEngine

        Task.detached {
            var ok = false
            do {
                let probe = try TestProbeAudio.bundledURL()
                _ = try await engine.transcribe(audioFileAt: probe, config: config)
                ok = true
            } catch let error as ASRError where error == ASRError.emptyResult {
                // 兜底：探针被判无语音（emptyResult）仍视为链路通（服务应答正常，
                // 与二级页测试同语义）。
                ok = true
            } catch {
                ok = false
            }
            if ok {
                AppLog.pipeline.info("asr use probe ok provider=\(provider.rawValue, privacy: .public)")
            } else {
                AppLog.pipeline.error("asr use probe failed provider=\(provider.rawValue, privacy: .public)")
            }
            await MainActor.run {
                useTestingProvider = nil
                if ok {
                    currentProvider = provider
                    environment.settings.asrProvider = provider
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
            providers: AppSettings.ASRProvider.allCases,
            account: SecretAccount.asrAccount(for:),
            secrets: environment.secrets)
    }

    /// Debug 自动化：`--asr-detail` 直接进入当前供应商的二级页（截图/走查脚本用，
    /// 与 `--llm-detail` 同款机制；仅 Debug 编译进二进制）。
    private func applyDebugDetailArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--asr-detail") else { return }
        selectedProvider = environment.settings.asrProvider
        #endif
    }

    /// Debug 自动化：`--asr-use-custom` 自动对 custom 家触发「使用」前置探测
    /// （TASK-120 失败路径截图/走查用——合成点击需辅助功能权限，此入口零权限
    /// 即可拍「测试中…」/Toast 瞬态；仅 Debug 编译进二进制）。
    private func applyDebugUseProbeArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--asr-use-custom") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000) // 等视图挂稳再触发
            use(.custom)
        }
        #endif
    }
}

/// 二级页 · 单供应商配置表单（沿 LLMProviderDetailView 骨构 + 听写参数卡；
/// 表单三层限宽同款：800 列 / 22 内距 / 顶 42（二级页标准））。
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

    /// 模型行（TASK-098 分离交互；行标题/hint/placeholder 为本页文案——custom 端点
    /// 「模型名」沿用旧文案，与 LLM 页「模型」有知情差异勿统一）。
    private var modelRow: some View {
        ProviderModelRow(
            presets: provider.modelPresets,
            customTitle: String(localized: "models.model"),
            customHint: String(localized: "models.model.custom.hint"),
            customPlaceholder: "my-asr / large-v3",
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
            placeholder: "fun-asr-flash-2026-06-15",
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
                GlassToggle(isOn: dialectBinding)
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
        // 「当前使用」chip 门槛与一级卡使用中一致：当前供应商且已配 Key（§41 追裁）。
        let account = SecretAccount.asrAccount(for: provider)
        keyConfigured = ((try? environment.secrets.get(account)) ?? "")?.isEmpty == false
        isCurrent = environment.settings.asrProvider == provider && keyConfigured
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
            // Key 增删即时联动「当前使用」chip（门槛 = 当前且已配 Key，§41 追裁）
            isCurrent = environment.settings.asrProvider == provider && keyConfigured
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
        let engine = environment.asrEngine

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
