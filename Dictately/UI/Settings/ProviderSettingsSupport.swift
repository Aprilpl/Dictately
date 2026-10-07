import SwiftUI

// MARK: - 供应商设置两页共享件（TASK-117 自两页同形 helper 抽出）
//
// 两页（ASRSettingsView / LLMSettingsView）二级化后沉淀了 10+ 个逐字节/近逐字节
// 相同的成员，本文件是它们的单一来源。**两页知情差异（AGENTS §22/§23/§26/§35 记载的
// 用户裁决）一律经参数注入，不得在此「统一」**：文案键命名空间（models.* vs
// settings.llm.*）、placeholder 措辞、Base URL 非法提示措辞、模型行标题（ASR custom
// 端点「模型名」）、一级页结构（ASR 特有 API/本地分段）等。
// 纯逻辑部分（effectiveModel / menuLabel / debugKeyStart / TestState / commitAPIKey /
// keyStates）为全等合一；视图部分为参数化共享。

/// 两页共享的纯逻辑（单一来源）。
enum ProviderSettingsSupport {
    /// 测试连接状态（两页同款；成功/失败携带消息文本）。
    enum TestState: Equatable {
        case idle
        case testing
        case success(String) // "连接成功 · 412ms"
        case failure(String) // "连接失败：<原因>"
    }

    /// 生效模型计算（TASK-096/098 用户裁决规则，两页同规）：下拉选「自定义模型」且
    /// ID 非空 → 用自定义 ID；否则用下拉预设。无预设供应商（custom 端点）恒为自定义
    /// ID 本身（可空）。save() 据此写 <asr|llm>.model.<provider>（生效键单一来源，
    /// live()/一级卡 chip 读它）。
    static func effectiveModel(
        hasPresets: Bool, preset: String, usesCustom: Bool, customID: String
    ) -> String {
        let id = customID.trimmingCharacters(in: .whitespaces)
        guard hasPresets else { return id }
        return usesCustom && !id.isEmpty ? id : preset
    }

    /// 下拉显示文本的确定性中段省略：>26 字符 → 前 15 +「…」+ 后 10（mono 12.5 下
    /// 值列可容 ≈27 字符；保留 vendor 前缀与 `:free` 等后缀辨识度）。短 ID 原样。
    static func menuLabel(for model: String) -> String {
        guard model.count > 26 else { return model }
        return "\(model.prefix(15))…\(model.suffix(10))"
    }

    /// Debug 自动化：`--key-edit` 直入编辑态、`--key-confirm` 直入失焦确认气泡
    /// （`--key-toast-*` 直入 Toast 瞬态）——截图/走查用，两页同名共用。
    static var debugKeyStart: APIKeyField.DebugStart {
        #if DEBUG
        if CommandLine.arguments.contains("--key-confirm") { return .confirming }
        if CommandLine.arguments.contains("--key-edit") { return .editing }
        if CommandLine.arguments.contains("--key-toast-saved") { return .toastSaved }
        if CommandLine.arguments.contains("--key-toast-unsaved") { return .toastUnsaved }
        #endif
        return .none
    }

    /// APIKeyField 提交落盘（空=清除该账户 Key，非空=保存；掩码串已被状态机拦截不会
    /// 到达）。账户名由调用方按页解析（SecretAccount.asrAccount/llmAccount(for:)）；
    /// 写穿透 CachingSecretStore 全链路立即可见；失败记日志返回 false（页面据此不刷新 chip）。
    @discardableResult
    static func commitAPIKey(
        _ value: String, account: String, secrets: SecretStore
    ) -> Bool {
        do {
            if value.isEmpty {
                try secrets.delete(account)
            } else {
                try secrets.set(value, for: account)
            }
            return true
        } catch {
            AppLog.pipeline.error("keychain write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 一级页 Key 状态全量刷新（有值 = true；providers = 两页各自的 allCases）。
    static func keyStates<P: Hashable>(
        providers: [P], account: (P) -> String, secrets: SecretStore
    ) -> [P: Bool] {
        var states: [P: Bool] = [:]
        for provider in providers {
            states[provider] = ((try? secrets.get(account(provider))) ?? "")?.isEmpty == false
        }
        return states
    }

    // MARK: 一级卡「使用」前置探测（TASK-120 先测后切）

    /// 探测用 LLM 配置：读该供应商**已保存**的分键配置 + 分账户 Key——live() 路由
    /// 「当前」供应商，对非当前目标家会读错（二级页 runTestConnection 同款警训）。
    /// Base URL 解析失败返回 nil（调用方按失败收口；不静默回落他家端点——存量保存值
    /// 经 urlOK 门禁理论恒合法，此为 defaults 直写绕过 UI 的防御位）。
    static func savedLLMConfig(
        provider: AppSettings.LLMProvider, settings: AppSettings, secrets: SecretStore
    ) -> LLMConfig? {
        guard let url = URL(string: settings.llmBaseURL(for: provider)
            .trimmingCharacters(in: .whitespaces)) else { return nil }
        let model = settings.llmModel(for: provider)
        return LLMConfig(
            baseURL: url,
            apiKey: (try? secrets.get(SecretAccount.llmAccount(for: provider))) ?? "",
            model: model,
            temperature: settings.llmTemperatureValue(for: provider),
            thinkingParams: ThinkingPolicy.params(
                provider: provider,
                model: model,
                effortLow: settings.llmReasoningEffort(for: provider)
                    == AppSettings.LLMReasoningEffort.low.rawValue),
            opencodeSessionID: settings.opencodeSessionID)
    }

    /// 探测用 ASR 配置：同上读已保存分键；audioFormat 固定 .mp3 对齐 TestProbeAudio
    /// 探针负载（契约 A 要求 format/MIME 与实际音频一致）。
    static func savedASRConfig(
        provider: AppSettings.ASRProvider, settings: AppSettings, secrets: SecretStore
    ) -> ASRConfig? {
        guard let url = URL(string: settings.asrBaseURL(for: provider)
            .trimmingCharacters(in: .whitespaces)) else { return nil }
        return ASRConfig(
            provider: provider,
            baseURL: url,
            apiKey: (try? secrets.get(SecretAccount.asrAccount(for: provider))) ?? "",
            model: settings.asrModel(for: provider),
            audioFormat: .mp3,
            languageHints: settings.languageHints,
            vocabulary: settings.asrVocabulary,
            keepDialect: settings.keepDialect)
    }

    /// 前置测试失败的 Toast 文案（两页共用固定短文案，TASK-120 用户裁决不含原因——
    /// 完整诊断进二级页「测试连接」看行内红字）。
    static var useBlockedToastText: String {
        String(localized: "settings.asr.use.blocked")
    }
}

// MARK: - 一级页 · 供应商卡

/// 供应商卡（两页同款语言）：名称 + chips + 「使用」按钮 + › + 描述；当前使用整卡蓝调。
/// 点卡进二级（onTapGesture，StyleList 先例——内嵌 Button 优先命中）。
/// 使用中/密钥 chips 键两页共用（models.provider.*）；「使用/使用中」按钮键两页命名
/// 空间不同，注入。
struct ProviderListCard: View {
    let name: String
    let cardDescription: String
    let isCurrent: Bool
    let hasKey: Bool
    /// 模型 chip 文本（空 = 不显示）。限宽 + 中段截断：超长模型 ID（如
    /// nvidia/nemotron-3-super-120b-a12b:free）溢出卡片右缘、压住「使用」按钮
    /// （2026-10-02 用户截图实锤）；中段截断保留 vendor 前缀与 :free 等后缀语义，
    /// 完整值在二级页模型行可见。
    let modelChip: String
    let inUseKey: LocalizedStringKey
    let useKey: LocalizedStringKey
    /// 该卡「使用」前置测试进行中 → 按钮变禁用态「测试中…」（TASK-120 先测后切；
    /// 文案复用共享键 settings.asr.testing，两页测试文案本就共用该命名空间）。
    var useTesting = false
    /// 页内任一前置测试进行中 → 其余卡「使用」禁用（一次只跑一个测试，避免静默吞点击）。
    var useDisabled = false
    let onUse: () -> Void
    let onOpen: () -> Void

    var body: some View {
        // 「使用中」显示门槛 = 当前供应商**且已配置 Key**（TASK-120 追裁：首装无任何
        // 配置时，默认供应商不得显示使用中——未配置的服务谈不上「使用中」；配好 Key
        // 后（或经「使用」测试通过切换后）自然回到使用中态）。
        let used = isCurrent && hasKey
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false) // 名称原子性：窄窗不在词中折行
                if used {
                    Chip(text: String(localized: "models.provider.inuse"), tone: .blue)
                }
                if hasKey {
                    Chip(text: String(localized: "models.provider.keyOk"), tone: .green)
                } else {
                    Chip(text: String(localized: "models.provider.needKey"), tone: .orange)
                }
                if !modelChip.isEmpty {
                    Chip(text: modelChip, tone: .neutral, font: Theme.mono(11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                Spacer(minLength: 12)
                if used {
                    Button(inUseKey) {}
                        .buttonStyle(.themePrimary)
                        .controlSize(.small)
                        .disabled(true)
                } else if useTesting {
                    Button("settings.asr.testing") {}
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                        .disabled(true)
                } else {
                    Button(useKey) { onUse() }
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                        .disabled(useDisabled)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Text(cardDescription)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(used ? Theme.blueTintBg : Theme.fillSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(used ? Theme.blueTintBorder : Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - 二级页 · 页头三件

/// 「‹ 返回」按钮（标题键两页各自 back 命名空间）。
struct ProviderDetailBackButton: View {
    let titleKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text(titleKey)
                    .font(.system(size: 13))
            }
            .foregroundStyle(Theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
    }
}

/// 供应商名 + 「使用中」/密钥 chips（两页逐字节同形；键两页共用 models.provider.* /
/// models.key.*）。
struct ProviderDetailTitleRow: View {
    let name: String
    let isCurrent: Bool
    let keyConfigured: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.text1)
            if isCurrent {
                Chip(text: String(localized: "models.provider.inuse"), tone: .blue)
            }
            if keyConfigured {
                Chip(text: String(localized: "models.key.configured"), tone: .green)
            } else {
                Chip(text: String(localized: "models.key.notconfigured"), tone: .orange)
            }
        }
    }
}

/// 小节标签（13.5 semibold tracking 1，TASK-082 规格；首节距页头 24、节间 36、下 16）。
struct ProviderSectionLabel: View {
    let key: LocalizedStringKey
    let first: Bool

    var body: some View {
        Text(key)
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.top, first ? 24 : 36)
            .padding(.bottom, 16)
    }
}

// MARK: - 值列与服务配置卡行

extension View {
    /// 值列宽度（2026-10-03 用户裁决 300——供应商两页局部值，覆盖 TASK-082 全站 230
    /// 终值；General/Hotkey 两页仍 230）。API Key chip 行另有 +10pt 右移（ProviderKeyRow）。
    func providerValueColumn<V: View>(_ view: V) -> some View {
        view.frame(width: 300, alignment: .leading)
    }
}

/// Base URL 行（hint 动态取自各家 catalog，非法时红字——custom 的 http 放行文案不同，
/// 由调用方注入；placeholder 两页措辞不同，注入）。
struct ProviderBaseURLRow: View {
    let urlOK: Bool
    let hint: String
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        SettingRow(
            title: "Base URL",
            hint: hint) {
            GlassField(
                placeholder, text: $text,
                width: 300, invalid: !urlOK) // 恰满块宽（TASK-082）
        }
    }
}

/// API Key 三态字段（2026-10-03 原型定稿）：展示态一枚状态 chip 即点击入口，
/// 编辑/确认交互全在 APIKeyField 内；页面只接 isConfigured 镜像 + onCommit 落盘。
/// 「获取 API Key ↗」官网外链（TASK-110）由组件内部渲染（仅未配置展示态、chip 右侧
/// 同行）；两页 chip 同款 +10 右移（2026-10-06 用户追裁，链接随整体右移对齐）。
struct ProviderKeyRow: View {
    let titleKey: LocalizedStringKey
    let hintKey: LocalizedStringKey
    let isConfigured: Bool
    let debugStart: APIKeyField.DebugStart
    let keyPageURL: URL?
    let onCommit: (String) -> Void

    var body: some View {
        SettingRow(titleKey, hint: hintKey) {
            providerValueColumn(
                APIKeyField(
                    isConfigured: isConfigured, debugStart: debugStart,
                    getKeyPageURL: keyPageURL
                ) { onCommit($0) }
                .padding(.leading, 10)) // 须在值列内：外层垫宽会被 300 定宽 frame + 行右锚定抵消
        }
    }
}

/// 模型行（TASK-096/098 分离交互，两页同构）：预设供应商 = 下拉常驻（末项「自定义
/// 模型」只是选项，不再把控件切换成输入框——可随时切回预设）；custom 端点（无预设）
/// 维持纯文本输入。预设供应商的模型行不再是卡内末行（下方还有自定义 ID 行），画分隔线。
/// 行标题/hint/placeholder 两页不同（ASR custom 端点「模型名」沿用旧文案），注入；
/// title/hint 传**已解析 String**（verbatim 渲染）——与两页原实现同为 SettingRow 的
/// String init，避免 LocalizedStringKey 管道对 CJK 标点的 locale-aware 塑形差
/// （像素对比实测同一文案两种管道栅格不同，TASK-117 验证实录）。
struct ProviderModelRow: View {
    let presets: [LLMModelPreset]
    /// custom 端点（无预设）行标题/hint 与输入 placeholder。
    let customTitle: String
    let customHint: String
    let customPlaceholder: LocalizedStringKey
    /// 预设供应商行标题/hint。
    let presetTitle: String
    let presetHint: String
    /// 下拉末项「自定义模型」的选项文案（已解析文本，Button 与下拉显示共用）。
    let customOptionText: String
    @Binding var customModelInput: String
    @Binding var presetModel: String
    @Binding var usesCustomModel: Bool

    var body: some View {
        if presets.isEmpty {
            SettingRow(
                title: customTitle, hint: customHint, divider: false) {
                providerValueColumn(
                    GlassField(customPlaceholder, text: $customModelInput, width: 300))
            }
        } else {
            SettingRow(
                title: presetTitle, hint: presetHint) {
                providerValueColumn(
                    ProviderModelMenu(
                        presets: presets,
                        customOptionText: customOptionText,
                        presetModel: $presetModel,
                        usesCustomModel: $usesCustomModel))
            }
        }
    }
}

/// 自定义模型 ID 行（TASK-096/098 用户裁决：与下拉分离 + 禁用态常驻）：
/// 下拉未选「自定义模型」→ 禁用半透明，值保留不清空（切走再切回不丢字）；
/// 选了自定义但为空 → 红框 + 字段下红字（保存/测试连接随之禁用）。卡内末行。
/// title/hint 同为已解析 String（渲染管道与两页原实现一致，见 ProviderModelRow 注释）。
struct ProviderCustomModelIDRow: View {
    let title: String
    let hint: String
    let emptyKey: LocalizedStringKey
    let placeholder: LocalizedStringKey
    let modelOK: Bool
    let usesCustomModel: Bool
    @Binding var customModelInput: String

    var body: some View {
        SettingRow(title: title, hint: hint, divider: false) {
            providerValueColumn(
                VStack(alignment: .leading, spacing: 4) {
                    GlassField(
                        placeholder, text: $customModelInput,
                        width: 300, invalid: !modelOK)
                        .disabled(!usesCustomModel)
                        .opacity(usesCustomModel ? 1 : 0.55)
                    if !modelOK {
                        Text(emptyKey)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.err)
                    }
                })
        }
    }
}

/// 预设下拉（两页同款控件语言；LLM reasoningMenu 同源）。
/// 溢出返工（2026-10-02 用户截图勘误，两页同守）：① Menu 外层 `.fixedSize()` 会向
/// 子树传播「按理想尺寸布局」，label 的 Text 无视提议宽度按整串绘制——改为水平不
/// 固定，中段截断才生效；② Menu label 在 macOS 走 AppKit 渲染，SwiftUI 截断有平台
/// 怪癖前科——显示文本另做确定性中段省略兜底（ProviderSettingsSupport.menuLabel，
/// 仅显示；存储值不变）。左缘校准（2026-10-02 用户二次反馈：模型首字母比 Base URL
/// 的 `h` 左偏 ~8pt）：NSMenu 吞掉 label 内边距、自带 ~4pt 内容留白——校准放外层
/// +8、label 框收窄 292 补偿：文本左缘 +12 ≈ GlassField 的 +11（同一条线），框右缘
/// 仍落在 300 值列边界（2026-10-03 值列 230→300 加宽后 292+8=300，补偿关系不变）。
struct ProviderModelMenu: View {
    let presets: [LLMModelPreset]
    /// 下拉末项「自定义模型」选项文案（已解析文本）。
    let customOptionText: String
    @Binding var presetModel: String
    @Binding var usesCustomModel: Bool

    /// 下拉显示文本：选了「自定义模型」显选项名；否则显预设 ID（长 ID 中段省略）。
    private var menuLabelText: String {
        usesCustomModel
            ? customOptionText
            : ProviderSettingsSupport.menuLabel(for: presetModel)
    }

    var body: some View {
        Menu {
            ForEach(presets, id: \.id) { preset in
                Button(preset.label) {
                    presetModel = preset.id
                    usesCustomModel = false
                }
            }
            Button(customOptionText) { usesCustomModel = true }
        } label: {
            Text(menuLabelText)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(width: 292, alignment: .leading)
                .background(FieldBackground())
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 8)
    }
}

// MARK: - 二级页 · 底部动作条

/// 测试连接（左）+ 保存主按钮（右，非法输入禁用，成功闪「✓ 已保存」）。
/// 测试连接状态文案两页共用（settings.asr.test*）；保存键与禁用条件两页不同
/// （LLM 多 temperatureOK），注入。
struct ProviderDetailBottomBar: View {
    let testDisabled: Bool
    let saveDisabled: Bool
    let testState: ProviderSettingsSupport.TestState
    @Binding var savedFlash: Bool
    let saveKey: LocalizedStringKey
    let savedKey: LocalizedStringKey
    let onTest: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("settings.asr.test") { onTest() }
                .buttonStyle(.themeGhost)
                .disabled(testDisabled)

            switch testState {
            case .idle: EmptyView()
            case .testing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("settings.asr.testing")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text3)
                }
            case .success(let message):
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ok)
            case .failure(let message):
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.err)
            }

            Spacer()

            Button(savedFlash ? savedKey : saveKey) { onSave() }
                .buttonStyle(.themePrimary)
                .disabled(saveDisabled)
        }
        .padding(.top, 16)
    }
}
