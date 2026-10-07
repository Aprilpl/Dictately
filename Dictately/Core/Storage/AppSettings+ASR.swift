import Foundation

// MARK: - ASR（TASK-115 自 AppSettings.swift 拆出，纯移动）

extension AppSettings {
    var keepDialect: Bool {
        get { bool(Key.keepDialect, default: false) }
        set { defaults.set(newValue, forKey: Key.keepDialect) }
    }

    /// 当前转写服务商（听写模型页卡片选择；默认阿里云 Qwen）。
    var asrProvider: ASRProvider {
        get { ASRProvider(rawValue: string(Key.asrProvider, default: "")) ?? .qwen }
        set { defaults.set(newValue.rawValue, forKey: Key.asrProvider) }
    }

    // 2026-10-06 两级页：按供应商分键存储（`asr.<字段>.<provider>`），平铺旧属性退役——
    // 存量经 settings.migrated.asrProviders 搬入分键，消费方一律走以下存取对。

    /// 供应商 Base URL（默认 = 各家官方端点，见 ASRProviderCatalog；custom 默认空 =
    /// 必须手填——本地网关允许 http，校验在 provider.baseURLIsValid）。
    func asrBaseURL(for provider: ASRProvider) -> String {
        string("asr.baseURL.\(provider.rawValue)", default: provider.defaultBaseURL)
    }

    func setASRBaseURL(_ value: String, for provider: ASRProvider) {
        defaults.set(value, forKey: "asr.baseURL.\(provider.rawValue)")
    }

    /// 供应商模型名（唯一「生效模型」键：ASRConfig.live / 一级卡 chip 读它；
    /// 默认 = 各家推荐模型，custom 默认空 = 请求不携带 model）。
    func asrModel(for provider: ASRProvider) -> String {
        string("asr.model.\(provider.rawValue)", default: provider.defaultModel)
    }

    func setASRModel(_ value: String, for provider: ASRProvider) {
        defaults.set(value, forKey: "asr.model.\(provider.rawValue)")
    }

    /// 模型下拉当前预设（TASK-098 分离交互同款；缺省回落各家推荐模型）。
    func asrModelPreset(for provider: ASRProvider) -> String {
        string("asr.model.preset.\(provider.rawValue)", default: provider.defaultModel)
    }

    func setASRModelPreset(_ value: String, for provider: ASRProvider) {
        defaults.set(value, forKey: "asr.model.preset.\(provider.rawValue)")
    }

    /// 下拉是否选「自定义模型」（默认 false）。生效模型 = usesCustom 且 customID 非空
    /// → customID，否则 preset——由设置页 save() 算好写入 asrModel（生效键单一来源）。
    func asrUsesCustomModel(for provider: ASRProvider) -> Bool {
        bool("asr.model.usesCustom.\(provider.rawValue)", default: false)
    }

    func setASRUsesCustomModel(_ value: Bool, for provider: ASRProvider) {
        defaults.set(value, forKey: "asr.model.usesCustom.\(provider.rawValue)")
    }

    /// 自定义模型 ID 文本（默认空；custom 端点供应商的模型行也绑此键）。
    func asrModelCustomID(for provider: ASRProvider) -> String {
        string("asr.model.customID.\(provider.rawValue)", default: "")
    }

    func setASRModelCustomID(_ value: String, for provider: ASRProvider) {
        defaults.set(value, forKey: "asr.model.customID.\(provider.rawValue)")
    }

    /// 热词表（如 {"Dictately": 5}），JSON 编码存 Data；解码失败回退空表。
    var asrVocabulary: [String: Int] {
        get {
            guard let data = defaults.data(forKey: Key.asrVocabulary) else { return [:] }
            return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        set {
            // [String:Int] 编码不会失败；防御性兜底：失败则移除键回到默认 [:]
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.asrVocabulary)
            } else {
                defaults.removeObject(forKey: Key.asrVocabulary)
            }
        }
    }
}
