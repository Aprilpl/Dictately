import Foundation

/// 音频封装格式（契约 A：`parameters.format` 与 Data URI MIME 必须与实际音频一致）。
/// App 录音产出 WAV（默认）；「测试连接」探测用内置 MP3（TestProbeAudio，2026-09-30 起）。
enum ASRAudioFormat: String, Equatable {
    case wav
    case mp3

    /// 契约 A `parameters.format` 值（wav / mp3，API 文档 §请求参数）。
    var parameterFormat: String { rawValue }

    /// Base64 Data URI 前缀（MIME 按文档 Base64 Tab：WAV→audio/wav，MP3→audio/mpeg）。
    var dataURIPrefix: String {
        switch self {
        case .wav: return "data:audio/wav;base64,"
        case .mp3: return "data:audio/mpeg;base64,"
        }
    }
}

/// 转写服务配置（PRD §4 契约 A + §3 AppSettings/Keychain 键）。
/// 值对象：每次转写前由 Pipeline 现读组装（设置改动即时生效）。
/// 多供应商（2026-10-01 对齐 v2-glass 听写模型页）：qwen 走契约 A（QwenASRClient），
/// openai/groq/mistral/custom 走 OpenAI 兼容 /audio/transcriptions（OpenAICompatibleASRClient）；
/// 分流在 RoutingASREngine，业务层只看 ASREngine 协议。
struct ASRConfig: Equatable {
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
        baseURL: URL = URL(string: "https://maas.qianwenaiapi.com")!,
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

    /// 从 AppSettings + SecretStore 组装生产配置（Key 读不到 = 空串，客户端据此报 invalidApiKey/badRequest）。
    /// TASK-048：入参为 SecretStore（组装点传 CachingSecretStore 包装，底层每账户每进程至多读一次）。
    /// 多供应商（2026-10-06 两级页）：baseURL/model 一律读分键存取（默认值 =
    /// ASRProviderCatalog 各家官方端点/推荐模型——openai/groq/mistral 端点不再硬编码）。
    static func live(settings: AppSettings, secrets: SecretStore) -> ASRConfig {
        let provider = settings.asrProvider
        return ASRConfig(
            provider: provider,
            baseURL: URL(string: settings.asrBaseURL(for: provider))
                ?? URL(string: "https://maas.qianwenaiapi.com")!,
            apiKey: (try? secrets.get(SecretAccount.asrAccount(for: provider))) ?? "",
            model: settings.asrModel(for: provider),
            languageHints: settings.languageHints,
            vocabulary: settings.asrVocabulary,
            keepDialect: settings.keepDialect
        )
    }
}
