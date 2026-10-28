import Foundation

/// 音频封装格式（契约 A：`parameters.format` 与 Data URI MIME 必须与实际音频一致）。
/// App 录音产出 WAV（默认）；「测试连接」探测用内置 MP3（TestProbeAudio，2026-09-30 起）。
enum ASRAudioFormat: String, Equatable {
    case wav
    case mp3

    /// 契约 A `parameters.format` 值（wav / mp3，API 文档 §请求参数）。
    var parameterFormat: String { rawValue }

    /// MIME 类型（WAV→audio/wav，MP3→audio/mpeg；Data URI 前缀、请求体「mime」日志镜像、
    /// OpenAI 兼容 multipart 的 fileMIME 三处共用本单点）。
    var mimeType: String {
        switch self {
        case .wav: return "audio/wav"
        case .mp3: return "audio/mpeg"
        }
    }

    /// Base64 Data URI 前缀（MIME 按文档 Base64 Tab）。
    var dataURIPrefix: String { "data:\(mimeType);base64," }
}

/// 转写服务配置（PRD §4 契约 A + §3 AppSettings/Keychain 键）。
/// 值对象：每次转写前由 Pipeline 现读组装（设置改动即时生效）。
/// 多供应商（2026-10-01 对齐 v2-glass 听写模型页）：qwen 走契约 A（QwenASRClient），
/// openai/groq/mistral/custom 走 OpenAI 兼容 /audio/transcriptions（OpenAICompatibleASRClient）；
/// 分流在 RoutingASREngine，业务层只看 ASREngine 协议。
struct ASRConfig: Equatable {
    /// qwen 官方域名兜底（= ASRProviderCatalog qwen defaultBaseURL 同源）：
    /// init 默认参数与 live 的 URL 解析失败回落共用单点，域名字符串只此一处。
    static let fallbackBaseURL = URL(string: AppSettings.ASRProvider.qwen.defaultBaseURL)!

    /// 转写服务商（决定端点形态与请求协议）。
    var provider: AppSettings.ASRProvider
    /// 服务域名根（qwen=官方域名可配；openai/groq=官方固定；custom=用户自填）。
    var baseURL: URL
    var apiKey: String
    var model: String
    /// 音频封装（默认 wav=App 录音格式；探测负载用 mp3）。
    var audioFormat: ASRAudioFormat
    /// 语言提示（≤4 个，上限校验在设置页）。
    var languageHints: [String]
    /// 即时热词（词 → 权重 1–5 或 50；仅 qwen 携带）。
    var vocabulary: [String: Int]
    var keepDialect: Bool

    init(
        provider: AppSettings.ASRProvider = .qwen,
        baseURL: URL = ASRConfig.fallbackBaseURL,
        apiKey: String = "",
        model: String = "qwen-audio-3.1-asr-flash",
        audioFormat: ASRAudioFormat = .wav,
        languageHints: [String] = ["zh", "en"],
        vocabulary: [String: Int] = [:],
        keepDialect: Bool = false
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.audioFormat = audioFormat
        self.languageHints = languageHints
        self.vocabulary = vocabulary
        self.keepDialect = keepDialect
    }

    /// qwen 完整端点：{baseURL}/api/v1/services/aigc/multimodal-generation/generation（PRD §4）。
    var endpoint: URL {
        baseURL.appendingPathComponent("api/v1/services/aigc/multimodal-generation/generation")
    }

    /// 请求 scheme 合法性：https 恒可；http 供自定义端点（本地网关）使用——
    /// 设置页按 provider 校验（ASRProviderCatalog.baseURLIsValid，官方服务 https-only），
    /// 此处兜底放行两种 scheme（与 LLMConfig.isHTTPScheme 对称：defaults 直写等绕过
    /// UI 的值，不让 Bearer Key 随非 http(s) scheme 外发）。
    var isHTTPScheme: Bool {
        let scheme = baseURL.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// 指定供应商版（文件转写页按页面选择快照组装——§76 页面模型选择不写回全局，
    /// 不能走 live 的 settings.asrProvider；字段组装两处同源防漂移）。
    static func live(
        settings: AppSettings, secrets: SecretStore, provider: AppSettings.ASRProvider
    ) -> ASRConfig {
        ASRConfig(
            provider: provider,
            baseURL: URL(string: settings.asrBaseURL(for: provider)) ?? fallbackBaseURL,
            apiKey: (try? secrets.get(SecretAccount.asrAccount(for: provider))) ?? "",
            model: settings.asrModel(for: provider),
            languageHints: settings.languageHints,
            vocabulary: settings.asrVocabulary,
            keepDialect: settings.keepDialect)
    }

    /// 从 AppSettings + SecretStore 组装生产配置（Key 读不到 = 空串，客户端据此报 invalidApiKey/badRequest）。
    /// TASK-048：入参为 SecretStore（组装点传 CachingSecretStore 包装，底层每账户每进程至多读一次）。
    /// 多供应商（2026-10-06 两级页）：baseURL/model 一律读分键存取（默认值 =
    /// ASRProviderCatalog 各家官方端点/推荐模型——openai/groq/mistral 端点不再硬编码）。
    /// 本地模式（TASK-134）：model 字段换写本地模型显示名（entries.asrModel 入库 →
    /// 统计页「本地模型」按目录名判定；本地引擎不消费其余 API 字段）。
    static func live(settings: AppSettings, secrets: SecretStore) -> ASRConfig {
        var config = live(settings: settings, secrets: secrets, provider: settings.asrProvider)
        if settings.asrMode == .local,
           let repoID = settings.activeLocalModel,
           let local = LocalModelCatalog.model(id: repoID) {
            config.model = local.name
        }
        return config
    }
}
