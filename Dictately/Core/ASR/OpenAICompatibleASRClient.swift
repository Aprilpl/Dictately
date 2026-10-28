import Foundation

/// OpenAI 兼容 /audio/transcriptions 转写客户端（多供应商：OpenAI / Groq / 自定义端点）。
///
/// 请求：POST {baseURL}/audio/transcriptions，multipart/form-data：
///   file（音频原文件）、model（非空时携带）、language（qwen 语义的 languageHints 不适用——
///   以 prompt 前缀传入语言/热词提示，效果因模型而异，见 v2-glass 听写模型页说明）。
/// 响应：{"text": "…"}。
///
/// 错误映射与 Qwen 客户端同表（ASRError）；体积上限 25MB（OpenAI 官方限制，未编码原文件）。
final class OpenAICompatibleASRClient: ASREngine {
    /// 原文件体积上限（OpenAI 官方 25MB）。
    static let fileSizeLimitBytes = 25 * 1024 * 1024

    private let transport: LoggedTransport
    /// 请求日志（nil = 不记录：单测默认形态；生产由 AppEnvironment 注入）。
    private let requestLog: RequestLog?

    /// session 注入供 URLProtocol stub 单测；生产用共享工厂（`NetworkSessionFactory`，
    /// request 60s / resource 120s，PRD §4）。
    init(session: URLSession = NetworkSessionFactory.make(), requestLog: RequestLog? = nil) {
        self.transport = LoggedTransport(session: session, requestLog: requestLog)
        self.requestLog = requestLog
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        let endpoint = config.baseURL.appendingPathComponent("audio/transcriptions")
        // 0. 空 Key 本地拦截（读文件前）：不发空 Bearer 让服务端 401 兜底——「未配置」与「无效」分开报
        guard !config.apiKey.isEmpty else {
            requestLog?.append(.rejected(
                kind: .asrCompatible, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "missingApiKey（本地拦截，未发请求）"))
            throw ASRError.missingApiKey
        }
        // 0b. scheme 兜底（读文件前）：与 LLM 客户端对称——绕过 UI 的配置
        //     不让 Bearer Key 随非 http(s) scheme 外发（http 为 custom 端点例外）
        guard config.isHTTPScheme else {
            requestLog?.append(.rejected(
                kind: .asrCompatible, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "invalidBaseURL（本地拦截，未发请求）"))
            throw ASRError.invalidBaseURL
        }

        // 1. 读文件 + 体积预判
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            requestLog?.append(.rejected(
                kind: .asrCompatible, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "音频文件读取失败：\(error.localizedDescription)"))
            throw ASRError.badRequest("音频文件读取失败：\(error.localizedDescription)")
        }
        guard fileData.count <= Self.fileSizeLimitBytes else {
            requestLog?.append(.rejected(
                kind: .asrCompatible, purpose: .transcribe,
                url: endpoint.absoluteString,
                request: ["audio": ["bytes": fileData.count] as [String: Any]],
                error: "audioTooLarge（\(fileData.count) 字节 > 上限）"))
            throw ASRError.audioTooLarge
        }

        // 2. 组 multipart 请求体
        let boundary = "Dictately-\(UUID().uuidString)"
        let fileMIME = config.audioFormat.mimeType
        let prompt = Self.promptPrefix(languageHints: config.languageHints, vocabulary: config.vocabulary)
        let body = Self.multipartBody(
            fileData: fileData,
            fileMIME: fileMIME,
            model: config.model,
            prompt: prompt,
            boundary: boundary
        )

        // 请求日志形态的请求体：multipart 字段镜像（file 只记元数据不记音频本体；
        // model/prompt 与 multipartBody 同条件携带——非空才带）
        var loggedRequest: [String: Any] = [
            "audio": ["mime": fileMIME, "bytes": fileData.count] as [String: Any],
        ]
        if !config.model.isEmpty { loggedRequest["model"] = config.model }
        if let prompt, !prompt.isEmpty { loggedRequest["prompt"] = prompt }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        // 请求日志条目（Authorization 脱敏），随请求推进补齐 outcome
        var log = RequestLog.Entry(
            kind: .asrCompatible,
            purpose: .transcribe,
            url: endpoint.absoluteString,
            headers: RequestLog.loggedHeaders(
                authorization: RequestLog.redactedAuthorization(apiKey: config.apiKey),
                contentType: "multipart/form-data; boundary=\(boundary)"),
            request: loggedRequest)

        // 3/4. 发请求 + 传输层出口（计时写 entries.asr_latency_ms；取消/网络错/状态码
        //      映射与 Qwen 客户端同表，由 LoggedTransport 统一）
        let (data, sentLog) = try await transport.send(
            request,
            entry: log,
            domainError: ASRError.self,
            mapURLError: { ASRError.map($0) },
            mapStatus: { ASRError.map(statusCode: $0, bodySummary: $1) },
            logHTTPError: { status, summary in
                if status >= 500 {
                    AppLog.pipeline.error("asr(compat) 5xx status=\(status, privacy: .public) body=\(summary, privacy: .public)")
                } else {
                    AppLog.pipeline.error("asr(compat) 4xx status=\(status, privacy: .public) body=\(summary, privacy: .public)")
                }
            })
        log = sentLog
        let latencyMs = log.latencyMs ?? 0

        // 5. 解析 {"text": "…"}
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            AppLog.pipeline.error("asr(compat) bad response: \(summary, privacy: .public)")
            log.error = "响应非 JSON"
            log.bodySummary = summary
            requestLog?.append(log)
            throw ASRError.badResponse
        }
        guard let text = decoded.text else {
            log.error = "text 缺失（badResponse）"
            requestLog?.append(log)
            throw ASRError.badResponse
        }
        if text.isEmpty {
            log.error = "text 为空（emptyResult）"
            requestLog?.append(log)
            throw ASRError.emptyResult
        }
        requestLog?.append(log)

        return ASRTranscript(text: text, durationSeconds: nil, requestID: nil, latencyMs: latencyMs)
    }

    // MARK: - multipart 与提示前缀

    /// multipart/form-data 组装（字段：file / model(非空) / prompt(非空)）。
    static func multipartBody(
        fileData: Data, fileMIME: String, model: String, prompt: String?, boundary: String
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio\"\r\n")
        append("Content-Type: \(fileMIME)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        if !model.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            append("\(model)\r\n")
        }
        if let prompt, !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    /// 语言提示/热词以 prompt 前缀传入（v2-glass：「以 prompt 前缀传入，效果因模型而异」）。
    static func promptPrefix(languageHints: [String], vocabulary: [String: Int]) -> String? {
        var lines: [String] = []
        if !languageHints.isEmpty {
            let labels = languageHints.map { code in
                AppSettings.languageOptionLabel(for: code) ?? code
            }
            lines.append("语言提示：\(labels.joined(separator: "、"))。")
        }
        if !vocabulary.isEmpty {
            let words = vocabulary.keys.sorted().joined(separator: "、")
            lines.append("热词：\(words)。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private extension OpenAICompatibleASRClient {
    struct ResponseBody: Codable {
        let text: String?
    }
}

/// 按 config.provider 分流的转写引擎（AppEnvironment 装配一次，业务层无感）。
/// qwen → QwenASRClient（契约 A）；openai/groq/mistral/custom → OpenAICompatibleASRClient
/// （Mistral 同族：/v1/audio/transcriptions 接受 Bearer，字段同构）。
/// 子客户端可注入（单测 stub session 用）；生产默认各自造默认 session。
final class RoutingASREngine: ASREngine {
    private let qwen: QwenASRClient
    private let compatible: OpenAICompatibleASRClient

    init(
        qwen: QwenASRClient = QwenASRClient(),
        compatible: OpenAICompatibleASRClient = OpenAICompatibleASRClient()
    ) {
        self.qwen = qwen
        self.compatible = compatible
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        switch config.provider {
        case .qwen: return try await qwen.transcribe(audioFileAt: url, config: config)
        case .openai, .groq, .mistral, .custom:
            return try await compatible.transcribe(audioFileAt: url, config: config)
        }
    }
}
