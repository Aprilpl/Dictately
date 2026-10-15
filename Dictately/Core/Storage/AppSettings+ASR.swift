import Foundation

// MARK: - ASR（TASK-115 自 AppSettings.swift 拆出，纯移动）

extension AppSettings {
    var keepDialect: Bool {
        get { bool(Key.keepDialect, default: false) }
        set { defaults.set(newValue, forKey: Key.keepDialect) }
    }

    /// 听写引擎模式（TASK-134）：API | 本地模型。任一侧点「使用」即切换（互斥，
    /// 原型语义）；非法存量值回退 .api。
    var asrMode: ASRMode {
        get { ASRMode(rawValue: string(Key.asrMode, default: "")) ?? .api }
        set { defaults.set(newValue.rawValue, forKey: Key.asrMode) }
    }

    /// 当前「使用中」的本地模型 repo id（空/未下载 = 本地模式不可用，回退 API 语义
    /// 由路由层判定；这里只存值）。
    var activeLocalModel: String? {
        get {
            let value = string(Key.activeLocalModel, default: "")
            return value.isEmpty ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: Key.activeLocalModel) }
    }

    /// 本地模型下载渠道（TASK-144）。键不存在时按系统地区自动初选并**立即持久化**
    /// （getter 落键是有意为之：此后即显式存储，地区/系统变化不再回自动）；
    /// 渠道菜单手动选择同写此键 = 记住默认。存量装机（升级用户）同样走首读初选——
    /// 国内用户得 modelScope 行为零变化，海外用户得 huggingFace（一次性影响，
    /// 可手动换回）。
    var localDownloadChannel: DownloadChannel {
        get {
            if let stored = defaults.string(forKey: Key.localDownloadChannel),
               let channel = DownloadChannel(rawValue: stored) {
                return channel
            }
            let picked = DownloadChannel.autoPick(regionCode: Locale.current.region?.identifier)
            defaults.set(picked.rawValue, forKey: Key.localDownloadChannel)
            return picked
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.localDownloadChannel)
            defaults.set(true, forKey: Key.localDownloadChannelManual)
        }
    }

    /// 渠道是否已由用户手动记住（菜单脚注文案区分「按地区自动/已记住」）。
    var localDownloadChannelManual: Bool {
        get { bool(Key.localDownloadChannelManual, default: false) }
        set { defaults.set(newValue, forKey: Key.localDownloadChannelManual) }
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
