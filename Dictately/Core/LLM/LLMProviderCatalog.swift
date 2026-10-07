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

extension AppSettings.LLMProvider {
    /// 卡片与二级页标题显示名。
    var displayName: String {
        switch self {
        case .openai: return String(localized: "settings.llm.provider.openai")
        case .zhipu: return String(localized: "settings.llm.provider.zhipu")
        case .deepseek: return String(localized: "settings.llm.provider.deepseek")
        case .bailian: return String(localized: "settings.llm.provider.bailian")
        case .openrouter: return String(localized: "settings.llm.provider.openrouter")
        case .opencode: return String(localized: "settings.llm.provider.opencode")
        case .custom: return String(localized: "settings.llm.provider.custom")
        }
    }

    /// 一级卡片描述行。
    var cardDescription: String {
        switch self {
        case .openai: return String(localized: "settings.llm.provider.openai.desc")
        case .zhipu: return String(localized: "settings.llm.provider.zhipu.desc")
        case .deepseek: return String(localized: "settings.llm.provider.deepseek.desc")
        case .bailian: return String(localized: "settings.llm.provider.bailian.desc")
        case .openrouter: return String(localized: "settings.llm.provider.openrouter.desc")
        case .opencode: return String(localized: "settings.llm.provider.opencode.desc")
        case .custom: return String(localized: "settings.llm.provider.custom.desc")
        }
    }

    /// 二级页 Base URL 行 hint（各家端点说明：双端点/无需 /v1 等，来自 docs/LLMDocs）。
    var baseURLHint: String {
        switch self {
        case .openai: return String(localized: "settings.llm.provider.openai.urlhint")
        case .zhipu: return String(localized: "settings.llm.provider.zhipu.urlhint")
        case .deepseek: return String(localized: "settings.llm.provider.deepseek.urlhint")
        case .bailian: return String(localized: "settings.llm.provider.bailian.urlhint")
        case .openrouter: return String(localized: "settings.llm.provider.openrouter.urlhint")
        case .opencode: return String(localized: "settings.llm.provider.opencode.urlhint")
        case .custom: return String(localized: "settings.llm.provider.custom.urlhint")
        }
    }

    /// 新装默认端点（custom 空 = 必须手填）。OpenCode 默认走 Go 包月订阅端点
    /// （2026-10-02 用户追裁：卡面描述即 Go 套餐，默认端点应一致；会话头已自动携带）。
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .deepseek: return "https://api.deepseek.com"
        case .bailian: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .opencode: return "https://opencode.ai/zen/go/v1"
        case .custom: return ""
        }
    }

    /// 「获取 API Key」官网外链（TASK-108）：二级页 Key 行 chip 下方文字链的目标。
    /// URL 为用户 2026-10-06 逐字提供，不做「修正」；阿里云一条链接与 ASR 侧 qwen
    /// 共用（同一 Qwen 账号体系）；custom 无官网返回 nil（不渲染）。
    var apiKeyURL: URL? {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .zhipu: return URL(string: "https://bigmodel.cn/apikey/platform")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .bailian: return URL(string: "https://platform.qianwenai.com/home/api-keys")
        case .openrouter: return URL(string: "https://openrouter.ai/workspaces/default/keys")
        case .opencode: return URL(string: "https://opencode.ai/console/")
        case .custom: return nil
        }
    }

    /// 模型预设（二级页下拉；custom 无预设纯手填）。
    var modelPresets: [LLMModelPreset] {
        switch self {
        case .openai:
            return [
                LLMModelPreset(id: "gpt-6-astra", badge: .flagship),
                LLMModelPreset(id: "gpt-6-luna", badge: .value),
                LLMModelPreset(id: "gpt-5.2"),
                LLMModelPreset(id: "gpt-5-mini"),
            ]
        case .zhipu:
            return [
                LLMModelPreset(id: "glm-5.3", badge: .flagship),
                LLMModelPreset(id: "glm-5.3-flash", badge: .lowPrice),
                LLMModelPreset(id: "glm-4.7-flash", badge: .free),
                LLMModelPreset(id: "glm-5.2"),
            ]
        case .deepseek:
            return [
                LLMModelPreset(id: "deepseek-flash", badge: .main),
                LLMModelPreset(id: "deepseek-v4-pro"),
            ]
        case .bailian:
            return [
                LLMModelPreset(id: "qwen3.8-flash", badge: .recommended),
                LLMModelPreset(id: "deepseek-v4.1-flash"),
            ]
        case .openrouter:
            return [
                LLMModelPreset(id: "deepseek/deepseek-chat"),
                LLMModelPreset(id: "openai/gpt-5.2"),
                LLMModelPreset(id: "qwen/qwen3.8-27b:free", badge: .free),
                LLMModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", badge: .free),
            ]
        case .opencode:
            return [
                LLMModelPreset(id: "glm-5.3-flash"),
                LLMModelPreset(id: "kimi-k3"),
                LLMModelPreset(id: "deepseek-v4.1-flash"),
                LLMModelPreset(id: "mimo-v2.6-flash"),
            ]
        case .custom:
            return []
        }
    }

    /// 新装默认模型（custom 空；须属于 modelPresets 之一，便于下拉回显选中项）。
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-6-luna"
        case .zhipu: return "glm-4.7-flash"
        case .deepseek: return "deepseek-flash"
        case .bailian: return "qwen3.8-flash"
        case .openrouter: return "deepseek/deepseek-chat"
        case .opencode: return "glm-5.3-flash"
        case .custom: return ""
        }
    }

    /// 自定义端点允许 http（2026-10-02 用户裁决：本地自建网关如 127.0.0.1 的
    /// OpenAI 兼容服务，明文仅限自控环境）；六家官方服务恒 https（PRD §7 例外仅此）。
    var allowsPlainHTTP: Bool { self == .custom }

    /// Base URL 合法性（设置页保存/测试连接同一判定）：需合法 URL 且含主机名；
    /// custom 放行 http(s)，其余 https-only。
    func baseURLIsValid(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              url.host != nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return allowsPlainHTTP
        default: return false
        }
    }
}
