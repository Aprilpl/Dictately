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

extension AppSettings.ASRProvider: ProviderBaseURLValidating {
    /// 供应商元数据单表（§85 表驱动化，与 LLMProviderCatalog 同构）：每家一张完整卡
    /// （含能力矩阵三布尔），编译器穷尽性保留。显示名/描述/端点提示的本地化键由
    /// rawValue 派生（models.provider.<case>[.desc/.urlhint]）。
    ///
    /// 各字段裁决出处：defaultBaseURL（qwen 域名 = 契约 A 端点根，路径由
    /// ASRConfig.endpoint 拼接）；apiKeyURL（2026-10-06 用户逐字提供勿修正）；
    /// qwen 预设只收契约 A 适用模型——qwen3-asr-flash 仅 OpenAI 兼容协议
    /// （docs/LLMDocs 语音识别文档 §4.3），不入列。
    private struct ProviderMetadata {
        let defaultBaseURL: String
        let apiKeyURL: URL?
        let modelPresets: [ASRModelPreset]
        /// 新装默认模型（custom 空；须属于 modelPresets 之一，便于下拉回显选中项）。
        let defaultModel: String
        // 能力矩阵（听写参数卡按此渲染；原 ASRSettingsView.caps(for:) 迁入）
        /// 语言提示：qwen 按顺序作 language_hints；兼容系作 prompt 前缀（客户端分流）。
        let supportsLanguageHints: Bool
        /// 即时热词（vocabulary）：仅 qwen（契约 A vocabulary_name 参数）。
        let supportsHotwords: Bool
        /// 方言保留（keep_dialect）：仅 qwen。
        let supportsDialect: Bool
    }

    private var metadata: ProviderMetadata {
        switch self {
        case .qwen:
            return ProviderMetadata(
                defaultBaseURL: "https://maas.qianwenaiapi.com",
                apiKeyURL: URL(string: "https://platform.qianwenai.com/home/api-keys"),
                modelPresets: [
                    ASRModelPreset(id: "qwen-audio-3.1-asr-flash", badge: .main),
                    ASRModelPreset(id: "fun-asr-flash-2026-06-15"),
                ],
                defaultModel: "qwen-audio-3.1-asr-flash",
                supportsLanguageHints: true,
                supportsHotwords: true,
                supportsDialect: true)
        case .openai:
            return ProviderMetadata(
                defaultBaseURL: "https://api.openai.com/v1",
                apiKeyURL: URL(string: "https://platform.openai.com/api-keys"),
                modelPresets: [
                    ASRModelPreset(id: "gpt-4o-transcribe", badge: .main),
                    ASRModelPreset(id: "gpt-4o-mini-transcribe", badge: .lowPrice),
                    ASRModelPreset(id: "whisper-1"),
                ],
                defaultModel: "gpt-4o-transcribe",
                supportsLanguageHints: true,
                supportsHotwords: false,
                supportsDialect: false)
        case .groq:
            return ProviderMetadata(
                defaultBaseURL: "https://api.groq.com/openai/v1",
                apiKeyURL: URL(string: "https://console.groq.com/keys"),
                modelPresets: [
                    ASRModelPreset(id: "whisper-large-v3-turbo", badge: .recommended),
                    ASRModelPreset(id: "whisper-large-v3"),
                ],
                defaultModel: "whisper-large-v3-turbo",
                supportsLanguageHints: false,
                supportsHotwords: false,
                supportsDialect: false)
        case .mistral:
            return ProviderMetadata(
                defaultBaseURL: "https://api.mistral.ai/v1",
                apiKeyURL: URL(string: "https://admin.mistral.ai/organization/api-keys"),
                modelPresets: [
                    ASRModelPreset(id: "voxtral-mini-latest", badge: .main),
                    ASRModelPreset(id: "voxtral-small-latest"),
                ],
                defaultModel: "voxtral-mini-latest",
                supportsLanguageHints: true,
                supportsHotwords: false,
                supportsDialect: false)
        case .custom:
            return ProviderMetadata(
                defaultBaseURL: "",
                apiKeyURL: nil,
                modelPresets: [],
                defaultModel: "",
                supportsLanguageHints: false,
                supportsHotwords: false,
                supportsDialect: false)
        }
    }

    /// 动态键查表（§90）：rawValue 插值不能传给 String(localized:) / 
    /// String.LocalizationValue——插值会被转成格式串占位符，查找键成
    /// `models.provider.%@` 必落空（TASK-159 第五批两页供应商卡全显原始键样
    /// 文本即此坑）。先拼全键再经 AppResources.bundle 查表；查不到回退键本身。
    private func localizedProvider(_ key: String) -> String {
        AppResources.bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 卡片与二级页标题显示名。
    var displayName: String { localizedProvider("models.provider.\(rawValue)") }

    /// 一级卡片描述行。
    var cardDescription: String { localizedProvider("models.provider.\(rawValue).desc") }

    /// 二级页 Base URL 行 hint（各家端点说明，来自 docs/LLMDocs）。
    var baseURLHint: String { localizedProvider("models.provider.\(rawValue).urlhint") }

    /// 新装默认端点（custom 空 = 必须手填）。
    var defaultBaseURL: String { metadata.defaultBaseURL }

    /// 「获取 API Key」官网外链（TASK-108）：二级页 Key 行 chip 下方文字链的目标。
    var apiKeyURL: URL? { metadata.apiKeyURL }

    /// 模型预设（二级页下拉；custom 无预设纯手填）。
    var modelPresets: [ASRModelPreset] { metadata.modelPresets }

    /// 新装默认模型。
    var defaultModel: String { metadata.defaultModel }

    /// 自定义端点允许 http（对齐 LLM 侧 2026-10-02 裁决：本地自建网关明文可用）；
    /// 四家官方服务恒 https。
    var allowsPlainHTTP: Bool { self == .custom }

    /// 语言提示能力。
    var supportsLanguageHints: Bool { metadata.supportsLanguageHints }

    /// 即时热词能力。
    var supportsHotwords: Bool { metadata.supportsHotwords }

    /// 方言保留能力。
    var supportsDialect: Bool { metadata.supportsDialect }
}
