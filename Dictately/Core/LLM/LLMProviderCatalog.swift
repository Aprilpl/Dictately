import Foundation

// MARK: - AI 服务供应商目录（2026-10-02 用户裁决：AI 服务页两级化）
//
// 元数据来源 = docs/LLMDocs 各家接入文档：默认 Base URL / 模型预设（附「免费」等短标注）/
// 卡片描述 / 端点提示。仅作「新装默认值 + UI 展示」——用户保存过的值以 AppSettings
// 分键（`llm.<字段>.<provider>`）为准，预设更新不覆盖已存值（与内置风格种子同一纪律）。

/// 模型预设（二级页「模型」下拉项）：id = 请求体 model 值，label 附短标注。
struct LLMModelPreset: Equatable {
    enum Badge: String {
        case flagship      // 旗舰
        case value         // 高性价比
        case free          // 免费
        case main          // 主力
        case lowPrice      // 低价
        case recommended   // 推荐

        var label: String {
            switch self {
            case .flagship: return String(localized: "settings.llm.model.badge.flagship")
            case .value: return String(localized: "settings.llm.model.badge.value")
            case .free: return String(localized: "settings.llm.model.badge.free")
            case .main: return String(localized: "settings.llm.model.badge.main")
            case .lowPrice: return String(localized: "settings.llm.model.badge.lowprice")
            case .recommended: return String(localized: "settings.llm.model.badge.recommended")
            }
        }
    }

    let id: String
    var badge: Badge?

    var label: String {
        id + (badge.map { " · \($0.label)" } ?? "")
    }
}

extension AppSettings.LLMProvider: ProviderBaseURLValidating {
    /// 供应商元数据单表（§85 表驱动化）：每家一张完整卡，此前 7 个平行 switch 收敛为
    /// 一个（编译器穷尽性保留——新增供应商 = 此处加一个 case，漏字段即编译失败）。
    /// 显示名/描述/端点提示的本地化键由 rawValue 派生（settings.llm.provider.<case>
    /// [.desc/.urlhint]），键与 case 名不再两处维护。
    ///
    /// 各字段裁决出处：defaultBaseURL（OpenCode=Go 包月订阅端点，2026-10-02 追裁）；
    /// defaultModel（六家各用自家默认，2026-10-10 TASK-128 用户裁决）；
    /// apiKeyURL（2026-10-06 用户逐字提供勿修正；阿里云一条与 ASR 侧 qwen 共用，
    /// 同一 Qwen 账号体系；custom 无官网 = nil 不渲染）。
    private struct ProviderMetadata {
        let defaultBaseURL: String
        let apiKeyURL: URL?
        let modelPresets: [LLMModelPreset]
        /// 新装默认模型（custom 空；须属于 modelPresets 之一，便于下拉回显选中项）。
        let defaultModel: String
    }

    private var metadata: ProviderMetadata {
        switch self {
        case .openai:
            return ProviderMetadata(
                defaultBaseURL: "https://api.openai.com/v1",
                apiKeyURL: URL(string: "https://platform.openai.com/api-keys"),
                modelPresets: [
                    LLMModelPreset(id: "gpt-6-astra", badge: .flagship),
                    LLMModelPreset(id: "gpt-6-luna", badge: .value),
                    LLMModelPreset(id: "gpt-5.2"),
                    LLMModelPreset(id: "gpt-5-mini"),
                ],
                defaultModel: "gpt-6-luna")
        case .deepseek:
            return ProviderMetadata(
                defaultBaseURL: "https://api.deepseek.com",
                apiKeyURL: URL(string: "https://platform.deepseek.com/api_keys"),
                modelPresets: [
                    LLMModelPreset(id: "deepseek-flash", badge: .main),
                    LLMModelPreset(id: "deepseek-v4-pro"),
                ],
                defaultModel: "deepseek-flash")
        case .bailian:
            return ProviderMetadata(
                defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                apiKeyURL: URL(string: "https://platform.qianwenai.com/home/api-keys"),
                modelPresets: [
                    LLMModelPreset(id: "qwen3.8-flash", badge: .recommended),
                    LLMModelPreset(id: "deepseek-v4.1-flash"),
                ],
                defaultModel: "qwen3.8-flash")
        case .openrouter:
            return ProviderMetadata(
                defaultBaseURL: "https://openrouter.ai/api/v1",
                apiKeyURL: URL(string: "https://openrouter.ai/workspaces/default/keys"),
                modelPresets: [
                    LLMModelPreset(id: "deepseek/deepseek-chat"),
                    LLMModelPreset(id: "openai/gpt-5.2"),
                    LLMModelPreset(id: "qwen/qwen3.8-27b:free", badge: .free),
                    LLMModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", badge: .free),
                ],
                defaultModel: "openai/gpt-5.2")
        case .opencode:
            return ProviderMetadata(
                defaultBaseURL: "https://opencode.ai/zen/go/v1",
                apiKeyURL: URL(string: "https://opencode.ai/console/"),
                modelPresets: [
                    LLMModelPreset(id: "glm-5.3-flash"),
                    LLMModelPreset(id: "kimi-k3"),
                    LLMModelPreset(id: "deepseek-v4.1-flash"),
                    LLMModelPreset(id: "mimo-v2.6-flash"),
                ],
                defaultModel: "mimo-v2.6-flash")
        case .custom:
            return ProviderMetadata(
                defaultBaseURL: "",
                apiKeyURL: nil,
                modelPresets: [],
                defaultModel: "")
        }
    }

    /// 动态键查表（§90）：rawValue 插值不能传给 String(localized:) / 
    /// String.LocalizationValue——插值会被转成格式串占位符，查找键成
    /// `settings.llm.provider.%@` 必落空（TASK-159 第五批两页供应商卡全显原始
    /// 键样文本即此坑）。先拼全键再经 AppResources.bundle 查表；查不到回退键本身。
    private func localizedProvider(_ key: String) -> String {
        AppResources.bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 卡片与二级页标题显示名。
    var displayName: String { localizedProvider("settings.llm.provider.\(rawValue)") }

    /// 一级卡片描述行。
    var cardDescription: String { localizedProvider("settings.llm.provider.\(rawValue).desc") }

    /// 二级页 Base URL 行 hint（各家端点说明：双端点/无需 /v1 等，来自 docs/LLMDocs）。
    var baseURLHint: String { localizedProvider("settings.llm.provider.\(rawValue).urlhint") }

    /// 新装默认端点（custom 空 = 必须手填）。
    var defaultBaseURL: String { metadata.defaultBaseURL }

    /// 「获取 API Key」官网外链（TASK-108）：二级页 Key 行 chip 下方文字链的目标。
    var apiKeyURL: URL? { metadata.apiKeyURL }

    /// 模型预设（二级页下拉；custom 无预设纯手填）。
    var modelPresets: [LLMModelPreset] { metadata.modelPresets }

    /// 新装默认模型。
    var defaultModel: String { metadata.defaultModel }

    /// 自定义端点允许 http（2026-10-02 用户裁决：本地自建网关如 127.0.0.1 的
    /// OpenAI 兼容服务，明文仅限自控环境）；六家官方服务恒 https（PRD §7 例外仅此）。
    var allowsPlainHTTP: Bool { self == .custom }
}
