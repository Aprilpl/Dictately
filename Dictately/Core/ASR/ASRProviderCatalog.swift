import Foundation

// MARK: - 听写模型供应商目录（2026-10-06 用户裁决：听写模型页两级化，对齐 AI 服务页）
//
// 元数据来源 = docs/LLMDocs 各家语音识别文档：默认 Base URL / 模型预设（附「主力」等
// 短标注）/ 卡片描述 / 端点提示 / 能力矩阵（语言提示 / 即时热词 / 方言保留）。
// 仅作「新装默认值 + UI 展示」——用户保存过的值以 AppSettings 分键
// （`asr.<字段>.<provider>`）为准，预设更新不覆盖已存值（与内置风格种子、
// LLMProviderCatalog 同一纪律）。

/// ASR 模型预设（二级页「模型」下拉项）：结构复用 LLM 侧预设类型（id + 短标注，
/// 标注文案为「主力/免费」等通用词，两目录共用）。
typealias ASRModelPreset = LLMModelPreset

extension AppSettings.ASRProvider {
    /// 卡片与二级页标题显示名。
    var displayName: String {
        switch self {
        case .qwen: return String(localized: "models.provider.qwen")
        case .openai: return String(localized: "models.provider.openai")
        case .groq: return String(localized: "models.provider.groq")
        case .mistral: return String(localized: "models.provider.mistral")
        case .custom: return String(localized: "models.provider.custom")
        }
    }

    /// 一级卡片描述行。
    var cardDescription: String {
        switch self {
        case .qwen: return String(localized: "models.provider.qwen.desc")
        case .openai: return String(localized: "models.provider.openai.desc")
        case .groq: return String(localized: "models.provider.groq.desc")
        case .mistral: return String(localized: "models.provider.mistral.desc")
        case .custom: return String(localized: "models.provider.custom.desc")
        }
    }

    /// 二级页 Base URL 行 hint（各家端点说明，来自 docs/LLMDocs）。
    var baseURLHint: String {
        switch self {
        case .qwen: return String(localized: "models.provider.qwen.urlhint")
        case .openai: return String(localized: "models.provider.openai.urlhint")
        case .groq: return String(localized: "models.provider.groq.urlhint")
        case .mistral: return String(localized: "models.provider.mistral.urlhint")
        case .custom: return String(localized: "models.provider.custom.urlhint")
        }
    }

    /// 新装默认端点（custom 空 = 必须手填；qwen 域名 = 契约 A 端点根，路径由
    /// ASRConfig.endpoint 拼接）。
    var defaultBaseURL: String {
        switch self {
        case .qwen: return "https://maas.qianwenaiapi.com"
        case .openai: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .custom: return ""
        }
    }

    /// 「获取 API Key」官网外链（TASK-108）：二级页 Key 行 chip 下方文字链的目标。
    /// URL 为用户 2026-10-06 逐字提供，不做「修正」；custom 无官网返回 nil（不渲染）。
    var apiKeyURL: URL? {
        switch self {
        case .qwen: return URL(string: "https://platform.qianwenai.com/home/api-keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .mistral: return URL(string: "https://admin.mistral.ai/organization/api-keys")
        case .custom: return nil
        }
    }

    /// 模型预设（二级页下拉；custom 无预设纯手填）。
    /// qwen 预设只收契约 A（同步识别 multimodal-generation）适用模型——
    /// qwen3-asr-flash 仅 OpenAI 兼容协议（docs/LLMDocs 语音识别文档 §4.3），不入列。
    var modelPresets: [ASRModelPreset] {
        switch self {
        case .qwen:
            return [
                ASRModelPreset(id: "qwen-audio-3.1-asr-flash", badge: .main),
                ASRModelPreset(id: "fun-asr-flash-2026-06-15"),
            ]
        case .openai:
            return [
                ASRModelPreset(id: "gpt-4o-transcribe", badge: .main),
                ASRModelPreset(id: "gpt-4o-mini-transcribe", badge: .lowPrice),
                ASRModelPreset(id: "whisper-1"),
            ]
        case .groq:
            return [
                ASRModelPreset(id: "whisper-large-v3-turbo", badge: .recommended),
                ASRModelPreset(id: "whisper-large-v3"),
            ]
        case .mistral:
            return [
                ASRModelPreset(id: "voxtral-mini-latest", badge: .main),
                ASRModelPreset(id: "voxtral-small-latest"),
            ]
        case .custom:
            return []
        }
    }

    /// 新装默认模型（custom 空；须属于 modelPresets 之一，便于下拉回显选中项）。
    var defaultModel: String {
        switch self {
        case .qwen: return "qwen-audio-3.1-asr-flash"
        case .openai: return "gpt-4o-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .mistral: return "voxtral-mini-latest"
        case .custom: return ""
        }
    }

    /// 自定义端点允许 http（对齐 LLM 侧 2026-10-02 裁决：本地自建网关明文可用）；
    /// 四家官方服务恒 https。
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

    // MARK: - 能力矩阵（听写参数卡按此渲染；原 ASRSettingsView.caps(for:) 迁入）

    /// 语言提示：qwen 按顺序作 language_hints；兼容系作 prompt 前缀（客户端分流）。
    var supportsLanguageHints: Bool {
        switch self {
        case .qwen, .openai, .mistral: return true
        case .groq, .custom: return false
        }
    }

    /// 即时热词（vocabulary）：仅 qwen（契约 A vocabulary_name 参数）。
    var supportsHotwords: Bool { self == .qwen }

    /// 方言保留（keep_dialect）：仅 qwen。
    var supportsDialect: Bool { self == .qwen }
}
