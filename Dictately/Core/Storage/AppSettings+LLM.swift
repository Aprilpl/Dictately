import Foundation

// MARK: - LLM（2026-10-02 两级页：按供应商分键存储，`llm.<字段>.<provider>`；
// TASK-115 自 AppSettings.swift 拆出，纯移动）

extension AppSettings {
    /// 当前 AI 服务供应商（一级卡片「使用」切换；默认 DeepSeek，非法原始值回退）。
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: string(Key.llmProvider, default: "")) ?? .deepseek }
        set { defaults.set(newValue.rawValue, forKey: Key.llmProvider) }
    }

    /// 供应商 Base URL（默认 = 各家官方端点，见 LLMProviderCatalog；custom 默认空 = 必须手填）。
    func llmBaseURL(for provider: LLMProvider) -> String {
        string("llm.baseURL.\(provider.rawValue)", default: provider.defaultBaseURL)
    }

    func setLLMBaseURL(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.baseURL.\(provider.rawValue)")
    }

    /// 供应商模型名（默认 = 各家推荐模型；custom 默认空）。
    func llmModel(for provider: LLMProvider) -> String {
        string("llm.model.\(provider.rawValue)", default: provider.defaultModel)
    }

    func setLLMModel(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.model.\(provider.rawValue)")
    }

    /// 模型下拉当前预设（TASK-096 分离交互；缺省回落各家推荐模型）。
    func llmModelPreset(for provider: LLMProvider) -> String {
        string("llm.model.preset.\(provider.rawValue)", default: provider.defaultModel)
    }

    func setLLMModelPreset(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.model.preset.\(provider.rawValue)")
    }

    /// 下拉是否选「自定义模型」（默认 false）。生效模型 = usesCustom 且 customID 非空
    /// → customID，否则 preset——由设置页 save() 算好写入 llmModel（生效键单一来源）。
    func llmUsesCustomModel(for provider: LLMProvider) -> Bool {
        bool("llm.model.usesCustom.\(provider.rawValue)", default: false)
    }

    func setLLMUsesCustomModel(_ value: Bool, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.model.usesCustom.\(provider.rawValue)")
    }

    /// 自定义模型 ID 文本（默认空；custom 端点供应商的模型行也绑此键）。
    func llmModelCustomID(for provider: LLMProvider) -> String {
        string("llm.model.customID.\(provider.rawValue)", default: "")
    }

    func setLLMModelCustomID(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.model.customID.\(provider.rawValue)")
    }

    /// 供应商温度原始输入文本（0–1，默认 "0.7"；空 = 回落默认 0.7）。存文本而非数值：
    /// 设置页需区分「未填」与「填 0」。
    func llmTemperatureText(for provider: LLMProvider) -> String {
        string("llm.temperatureText.\(provider.rawValue)", default: "0.7")
    }

    func setLLMTemperatureText(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.temperatureText.\(provider.rawValue)")
    }

    /// 供应商温度解析值：空 = 默认 0.7；非法/越界 → nil（请求不携带，不送脏值）。
    func llmTemperatureValue(for provider: LLMProvider) -> Double? {
        let text = llmTemperatureText(for: provider).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0.7 }
        guard let value = Double(text), (0...1).contains(value) else { return nil }
        return value
    }

    /// 供应商推理思考（"low" = 开启最低档；空 = 关闭。关闭/开启的实际请求参数由
    /// ThinkingPolicy 按供应商分派——「关闭」必须显式发各家关闭参数，非省略）。
    func llmReasoningEffort(for provider: LLMProvider) -> String {
        string("llm.reasoningEffort.\(provider.rawValue)", default: "")
    }

    func setLLMReasoningEffort(_ value: String, for provider: LLMProvider) {
        defaults.set(value, forKey: "llm.reasoningEffort.\(provider.rawValue)")
    }

    // 以下旧名 = 「当前供应商」快捷读写（LLMConfig/管道与既有测试零改动；
    /// 写入落到当前供应商的分键上，读不到旧全局键——迁移已把存量搬入 DeepSeek 槽）。

    var llmBaseURL: String {
        get { llmBaseURL(for: llmProvider) }
        set { setLLMBaseURL(newValue, for: llmProvider) }
    }

    var llmModel: String {
        get { llmModel(for: llmProvider) }
        set { setLLMModel(newValue, for: llmProvider) }
    }

    var llmTemperatureText: String {
        get { llmTemperatureText(for: llmProvider) }
        set { setLLMTemperatureText(newValue, for: llmProvider) }
    }

    var llmTemperatureValue: Double? {
        llmTemperatureValue(for: llmProvider)
    }

    var llmReasoningEffort: String {
        get { llmReasoningEffort(for: llmProvider) }
        set { setLLMReasoningEffort(newValue, for: llmProvider) }
    }

    /// OpenCode 直连稳定会话 ID（`x-opencode-session` 头用；docs/LLMDocs §8.2：
    /// 缺失即 400 MissingSessionID——用户实测 OpenCode Go「请求被拒绝」的根因）。
    /// 首次访问生成 UUID 并持久化——跨启动稳定，符合「稳定会话」要求；无 setter（只读自生成）。
    var opencodeSessionID: String {
        let existing = string(Key.opencodeSessionID, default: "")
        if !existing.isEmpty { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.opencodeSessionID)
        return id
    }
}
