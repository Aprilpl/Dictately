import Foundation

/// LLM 润色服务错误分类（PRD §4 契约 B 错误映射）。
/// 语气与 kindKey 规约同 ASRError（userMessage 短原因、kindKey 入库稳定标识）。
enum LLMError: Error, Equatable {
    case invalidBaseURL       // scheme 非 http(s)（FR-007：https-only，自定义端点例外放行 http；设置页保存前也拦一道）
    case networkUnreachable
    case timeout
    case invalidApiKey        // 401/403
    case rateLimited          // 429
    case badRequest(String)   // 其他 4xx（契约 B 未列举，对称 ASR 处理，摘要入日志）
    case serverError          // 5xx
    case emptyResult          // choices 空 / content 空字符串（§4 B）
    case badResponse          // 非 JSON / 结构不符

    var userMessage: String {
        switch self {
        case .invalidBaseURL: return "Base URL 无效：需以 http(s):// 开头（官方服务须 https）"
        case .networkUnreachable: return "网络不可用"
        case .timeout: return "网络超时"
        case .invalidApiKey: return "API Key 无效"
        case .rateLimited: return "请求过频，稍后重试"
        case .badRequest: return "请求被拒绝"
        case .serverError: return "服务暂时不可用"
        case .emptyResult: return "润色返回为空"
        case .badResponse: return "响应异常"
        }
    }

    /// 网络类错误（FR-013 自动重试一次的判定集合）。
    var isNetworkError: Bool {
        self == .networkUnreachable || self == .timeout
    }

    var kindKey: String {
        switch self {
        case .invalidBaseURL: return "invalidBaseURL"
        case .networkUnreachable: return "networkUnreachable"
        case .timeout: return "timeout"
        case .invalidApiKey: return "invalidApiKey"
        case .rateLimited: return "rateLimited"
        case .badRequest: return "badRequest"
        case .serverError: return "serverError"
        case .emptyResult: return "emptyResult"
        case .badResponse: return "badResponse"
        }
    }

    /// 设置页「测试连接」的失败文案（2026-10-02 用户排障裁决）：badRequest 是 4xx 的
    /// 不透明兜底（MissingSessionID / 模型下线 / 额度窗口等都长这样）——附状态码与
    /// body 摘要，无日志场景也能自诊；其余语义化错误附状态码便于对照文档。
    var diagnosticMessage: String {
        switch self {
        case .badRequest(let summary):
            let head = summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140)
            return head.isEmpty ? "\(userMessage)（400）" : "\(userMessage)（400）：\(head)"
        case .invalidApiKey: return "\(userMessage)（401/403）"
        case .rateLimited: return "\(userMessage)（429）"
        default: return userMessage
        }
    }

    static func map(_ error: URLError) -> LLMError {
        switch error.code {
        case .timedOut: return .timeout
        default: return .networkUnreachable
        }
    }

    static func map(statusCode: Int, bodySummary: String) -> LLMError {
        switch statusCode {
        case 401, 403: return .invalidApiKey
        case 429: return .rateLimited
        case 400..<500: return .badRequest(bodySummary)
        default: return .serverError
        }
    }
}

/// LLM 服务配置（PRD §4 契约 B + §3 AppSettings/Keychain 键）。
/// temperature 为可选：nil = 不携带参数，由服务端默认（v2-glass AI 服务页
/// 「空为默认」语义）。思考参数经 ThinkingPolicy 按供应商分派（2026-10-04
/// 裁决：默认关闭且生效、开启即最低档），不再有平铺 reasoningEffort 通道。
struct LLMConfig: Equatable {
    var baseURL: URL
    var apiKey: String
    var model: String
    var temperature: Double?
    var thinkingParams: ThinkingParams
    /// OpenCode（opencode.ai）直连稳定会话 ID（docs/LLMDocs §8.2：缺失即 400
    /// MissingSessionID）；非 OpenCode 端点留空不生效。
    var opencodeSessionID: String

    init(
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
        apiKey: String = "",
        model: String = "deepseek-flash",
        temperature: Double? = nil,
        thinkingParams: ThinkingParams = ThinkingParams(),
        opencodeSessionID: String = ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.thinkingParams = thinkingParams
        self.opencodeSessionID = opencodeSessionID
    }

    /// 完整端点：{baseURL}/chat/completions（契约 B）。
    var endpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    /// 请求 scheme 合法性：https 恒可；http 供自定义端点（本地自建网关）使用——
    /// 设置页按 provider 校验（LLMProvider.baseURLIsValid，六家官方服务 https-only），
    /// 此处兜底放行两种 scheme（PRD §7 全 https 的例外仅自定义端点，AGENTS §22 追裁三）。
    var isHTTPScheme: Bool {
        let scheme = baseURL.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// 按端点附加的请求头：OpenCode（opencode.ai，Zen/Go 均是）要求稳定会话头
    /// `x-opencode-session`——Go 直连缺失即 400 MissingSessionID（LLMDocs 实测）；
    /// Zen 端点忽略多余头，一并携带作客户端会话标识。
    var extraHTTPHeaders: [String: String] {
        guard baseURL.host?.hasSuffix("opencode.ai") == true, !opencodeSessionID.isEmpty else { return [:] }
        return ["x-opencode-session": opencodeSessionID]
    }

    /// 从 AppSettings + SecretStore 组装生产配置（TASK-048：SecretStore + 读穿透缓存）。
    /// 2026-10-02 两级页：按「当前供应商」取分键配置与分账户 Key（七家见 LLMProviderCatalog）。
    /// 温度取 llmTemperatureText(for:) 解析值（空/非法/越界 → nil 不携带）；
    /// 推理思考仅 "low" 视为开启，其余值（含历史 medium/high）一律关闭，经
    /// ThinkingPolicy 分派出「真正生效」的关闭参数。
    static func live(settings: AppSettings, secrets: SecretStore) -> LLMConfig {
        let provider = settings.llmProvider
        let model = settings.llmModel(for: provider)
        let effortLow = settings.llmReasoningEffort(for: provider)
            == AppSettings.LLMReasoningEffort.low.rawValue
        return LLMConfig(
            baseURL: URL(string: settings.llmBaseURL(for: provider)) ?? URL(string: "https://api.deepseek.com")!,
            apiKey: (try? secrets.get(SecretAccount.llmAccount(for: provider))) ?? "",
            model: model,
            temperature: settings.llmTemperatureValue(for: provider),
            thinkingParams: ThinkingPolicy.params(provider: provider, model: model, effortLow: effortLow),
            opencodeSessionID: settings.opencodeSessionID
        )
    }
}

/// LLM 调用结果。
struct LLMResult: Equatable {
    /// 润色后文本（已 trim）。
    let text: String
    let model: String
    let latencyMs: Int
}

/// LLM 引擎协议（引擎层协议化，PRD §7；供应商替换不动业务层）。
protocol LLMEngine: AnyObject {
    /// 以 system+user 双消息完成一次润色（StyleExecutor 负责模板→消息组装；
    /// 2026-10-04 智谱 1214 修复：system-only 单消息不被接受，双消息为七家
    /// 文档示例一致的标准形态）。
    func complete(system: String, user: String, config: LLMConfig) async throws -> LLMResult
    /// 测试连接（契约 B 注：messages ping + max_tokens 1，供设置页）。
    func testConnection(config: LLMConfig) async throws -> Int // 返回耗时 ms
}
