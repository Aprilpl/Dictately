import Foundation

/// 转写错误分类（PRD §4 契约 A 错误映射 + §11 转写表现全表）。
/// `userMessage` 给面板/历史失败态的短原因（一行文案由 Pipeline 组装，见 TASK-019/020）。
enum ASRError: Error, Equatable {
    /// HTTP 401/403——Key 无效或无权限。
    case invalidApiKey
    /// Key 未配置（客户端发送前本地拦截，不发空 Bearer——与 401「无效」区分，
    /// 2026-10-03：空 Key 曾靠服务端 401 兜底，两种故障同文案无法自诊）。
    case missingApiKey
    /// Base URL scheme 非 http(s)（客户端发送前本地拦截；http 为自定义端点的文档化
    /// 例外，官方服务 https-only 由设置页校验——与 LLMError.invalidBaseURL 对称）。
    case invalidBaseURL
    /// HTTP 429——请求过频。
    case rateLimited
    /// HTTP 4xx 其他——携带 body 摘要（截断，不含 Key）。
    case badRequest(String)
    /// HTTP 5xx——服务端错误（request_id 已另行记日志）。
    case serverError
    /// URLError.notConnectedToInternet / .cannotFindHost / .networkConnectionLost。
    case networkUnreachable
    /// URLError.timedOut。
    case timeout
    /// 无语音：200 但 output.text 为空字符串，或 400 ASR_RESPONSE_HAVE_NO_WORDS（实测，见 map）。
    case emptyResult
    /// 响应缺 output.text 或 body 非 JSON（§11：记录原始响应摘要到日志）。
    case badResponse
    /// 编码后体积超 Qwen 10MB 上限（发送前预判，PRD §11）。
    case audioTooLarge

    /// 用户可读短原因（语气按 product-vision §4：工程师式诚实，无安抚词）。
    var userMessage: String {
        switch self {
        case .invalidApiKey: return "API Key 无效"
        case .missingApiKey: return "API Key 未配置"
        case .invalidBaseURL: return "服务地址无效"
        case .rateLimited: return "请求过频，稍后重试"
        case .badRequest: return "请求被拒绝"
        case .serverError: return "服务暂时不可用"
        case .networkUnreachable: return "网络不可用"
        case .timeout: return "网络超时"
        case .emptyResult: return "没有识别到语音"
        case .badResponse: return "响应异常"
        case .audioTooLarge: return "录音过长"
        }
    }

    /// 网络类错误（FR-013 自动重试一次的判定集合）。
    var isNetworkError: Bool {
        self == .networkUnreachable || self == .timeout
    }

    /// 入库稳定标识（entries.error_kind 列；与用户文案解耦，勿改已有值）。
    var kindKey: String {
        switch self {
        case .invalidApiKey: return "invalidApiKey"
        case .missingApiKey: return "missingApiKey"
        case .invalidBaseURL: return "invalidBaseURL"
        case .rateLimited: return "rateLimited"
        case .badRequest: return "badRequest"
        case .serverError: return "serverError"
        case .networkUnreachable: return "networkUnreachable"
        case .timeout: return "timeout"
        case .emptyResult: return "emptyResult"
        case .badResponse: return "badResponse"
        case .audioTooLarge: return "audioTooLarge"
        }
    }

    // MARK: - 映射（PRD §4 错误映射逐条对应）

    /// URLError → ASRError。未列举的网络类错误保守归入 networkUnreachable
    /// （.cannotConnectToHost/.dnsLookupFailed 等对用户而言都是「网络不可用」）。
    static func map(_ error: URLError) -> ASRError {
        switch error.code {
        case .timedOut: return .timeout
        default: return .networkUnreachable
        }
    }

    /// HTTP 状态码（非 2xx）→ ASRError。bodySummary 已由调用方截断。
    static func map(statusCode: Int, bodySummary: String) -> ASRError {
        switch statusCode {
        case 401, 403: return .invalidApiKey
        case 429: return .rateLimited
        case 400..<500:
            // TASK-022 验收实测（2026-09-30，qwen-audio-3.1-asr-flash）：纯静音/无语音
            // 音频服务端返回 400 CLIENT_ERROR "ASR_RESPONSE_HAVE_NO_WORDS"，而非
            // 200 + 空 text。语义为「没有识别到语音」→ emptyResult：
            // 设置页测试连接（1s 静音探测）据此判「服务应答正常」，面板给准确文案。
            if bodySummary.contains("ASR_RESPONSE_HAVE_NO_WORDS") { return .emptyResult }
            return .badRequest(bodySummary)
        default: return .serverError
        }
    }
}
