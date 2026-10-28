import Foundation

/// Qwen-Audio-3.x-ASR-Flash 非流式客户端（PRD §4 契约 A 逐字实现）。
///
/// 请求：POST {baseURL}/api/v1/services/aigc/multimodal-generation/generation
/// Headers：Authorization Bearer、Content-Type application/json、X-DashScope-SSE: disable
/// Body：WAV → Base64 Data URI（`data:audio/wav;base64,…`）；parameters.format="wav"、
/// sample_rate="16000"（**字符串**）；language_hints/vocabulary/keep_dialect 按需携带。
///
/// 线程：async 函数体运行于 Swift 并发协作池（非主线程）；Base64 编码与请求 await
/// 均不阻塞 UI——PRD「编码在后台线程」由此满足（调用方无需再包 Task.detached）。
final class QwenASRClient: ASREngine {
    /// 编码后（Base64）体积上限：Qwen 服务 10MB（PRD §11 audioTooLarge 预判）。
    static let encodedSizeLimitBytes = 10 * 1024 * 1024

    private let transport: LoggedTransport
    /// 请求日志（nil = 不记录：单测默认形态；生产由 AppEnvironment 注入）。
    private let requestLog: RequestLog?

    /// session 注入供 URLProtocol stub 单测；生产用共享工厂（`NetworkSessionFactory`，
    /// PRD §4 超时预算 request 60s / resource 120s）。
    init(session: URLSession = NetworkSessionFactory.make(), requestLog: RequestLog? = nil) {
        self.transport = LoggedTransport(session: session, requestLog: requestLog)
        self.requestLog = requestLog
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        let endpoint = config.endpoint
        // 0. 空 Key 本地拦截（读文件前）：不发空 Bearer 让服务端 401 兜底——「未配置」与「无效」分开报
        guard !config.apiKey.isEmpty else {
            requestLog?.append(.rejected(
                kind: .asrQwen, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "missingApiKey（本地拦截，未发请求）"))
            throw ASRError.missingApiKey
        }
        // 0b. scheme 兜底（读文件前）：与 LLM 客户端对称——绕过 UI 的配置
        //     不让 Bearer Key 随非 http(s) scheme 外发（http 为 custom 端点例外）
        guard config.isHTTPScheme else {
            requestLog?.append(.rejected(
                kind: .asrQwen, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "invalidBaseURL（本地拦截，未发请求）"))
            throw ASRError.invalidBaseURL
        }

        // 1. 读文件 + 体积预判（Base64 膨胀 4/3）
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            // §11 存储表：音频已清理 → 不可重跑；归 badRequest 携带原因
            //（上游 UI 对音频缺失条目另有「音频已过期清理」禁用态，不走本错误）。
            requestLog?.append(.rejected(
                kind: .asrQwen, purpose: .transcribe,
                url: endpoint.absoluteString,
                error: "音频文件读取失败：\(error.localizedDescription)"))
            throw ASRError.badRequest("音频文件读取失败：\(error.localizedDescription)")
        }
        guard fileData.count * 4 / 3 <= Self.encodedSizeLimitBytes else {
            requestLog?.append(.rejected(
                kind: .asrQwen, purpose: .transcribe,
                url: endpoint.absoluteString,
                request: ["audio": ["bytes": fileData.count] as [String: Any]],
                error: "audioTooLarge（编码后 \(fileData.count * 4 / 3) 字节 > 上限）"))
            throw ASRError.audioTooLarge
        }

        // 2. 组请求（编码在协作池线程，非主线程）——Data URI MIME 与 parameters.format
        //    跟随实际音频封装（契约 A：两者须一致；wav=App 录音，mp3=测试连接探测）
        let requestBody = RequestBody(
            model: config.model,
            input: .init(messages: [
                .init(content: [.init(data: config.audioFormat.dataURIPrefix + fileData.base64EncodedString())])
            ]),
            parameters: .init(
                format: config.audioFormat.parameterFormat,
                sampleRate: "16000",
                languageHints: config.languageHints.isEmpty ? nil : config.languageHints,
                vocabulary: config.vocabulary.isEmpty ? nil : config.vocabulary,
                keepDialect: config.keepDialect ? true : nil
            )
        )
        let bodyData = try JSONEncoder().encode(requestBody)

        // 请求日志形态的请求体：参数与上方 RequestBody 逐字段镜像（音频只记元数据，
        // 不记 base64——一次录音的 base64 即 1–2MB，落盘日志即爆炸）；改参数两处同步。
        var loggedParameters: [String: Any] = [
            "format": config.audioFormat.parameterFormat,
            "sample_rate": "16000",
        ]
        if !config.languageHints.isEmpty { loggedParameters["language_hints"] = config.languageHints }
        if !config.vocabulary.isEmpty { loggedParameters["vocabulary"] = config.vocabulary }
        if config.keepDialect { loggedParameters["keep_dialect"] = true }
        let loggedRequest: [String: Any] = [
            "model": config.model,
            "parameters": loggedParameters,
            "audio": [
                "mime": config.audioFormat.mimeType,
                "bytes": fileData.count,
            ] as [String: Any],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")

        // 请求日志条目（Authorization 脱敏），随请求推进补齐 outcome
        var log = RequestLog.Entry(
            kind: .asrQwen,
            purpose: .transcribe,
            url: endpoint.absoluteString,
            headers: RequestLog.loggedHeaders(
                authorization: RequestLog.redactedAuthorization(apiKey: config.apiKey),
                contentType: "application/json",
                extra: ["X-DashScope-SSE": "disable"]),
            request: loggedRequest)

        // 3/4. 发请求 + 传输层出口（计时覆盖编码后→响应，写 entries.asr_latency_ms；
        //      取消/网络错/状态码映射 §4 错误映射全表由 LoggedTransport 统一——
        //      4xx/5xx body 均落日志，401（Key 无效）与 400（请求被拒）的区分只能看
        //      body（2026-10-01 排查教训））
        let (data, sentLog) = try await transport.send(
            request,
            entry: log,
            domainError: ASRError.self,
            mapURLError: { ASRError.map($0) },
            mapStatus: { ASRError.map(statusCode: $0, bodySummary: $1) },
            logHTTPError: { status, summary in
                if status >= 500 {
                    AppLog.pipeline.error("asr 5xx status=\(status, privacy: .public) body=\(summary, privacy: .public)")
                } else {
                    AppLog.pipeline.error("asr 4xx status=\(status, privacy: .public) body=\(summary, privacy: .public)")
                }
            })
        log = sentLog

        // 5. 解析响应：output 缺失/text 为 nil → badResponse；空串 → emptyResult
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            AppLog.pipeline.error("asr bad response: \(summary, privacy: .public)")
            log.error = "响应非 JSON"
            log.bodySummary = summary
            requestLog?.append(log)
            throw ASRError.badResponse
        }
        guard let output = decoded.output else {
            log.error = "output 缺失（badResponse）"
            requestLog?.append(log)
            throw ASRError.badResponse
        }
        guard let text = output.text else {
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

        return ASRTranscript(
            text: text,
            durationSeconds: decoded.usage?.duration,
            requestID: decoded.request_id,
            latencyMs: log.latencyMs ?? 0
        )
    }
}

// MARK: - 契约 A 的 Codable 镜像（字段名与 PRD §4 逐字一致）

private extension QwenASRClient {
    struct RequestBody: Codable {
        let model: String
        let input: Input
        let parameters: Parameters

        struct Input: Codable {
            let messages: [Message]
            struct Message: Codable {
                let role = "user"
                let content: [Content]
                enum CodingKeys: String, CodingKey {
                    case role, content
                }
                struct Content: Codable {
                    let type = "input_audio"
                    let inputAudio: InputAudio
                    enum CodingKeys: String, CodingKey {
                        case type
                        case inputAudio = "input_audio"
                    }
                    struct InputAudio: Codable {
                        let data: String
                    }
                    init(data: String) {
                        self.inputAudio = .init(data: data)
                    }
                }
            }
        }

        struct Parameters: Codable {
            let format: String
            let sampleRate: String
            var languageHints: [String]?
            var vocabulary: [String: Int]?
            var keepDialect: Bool?
            enum CodingKeys: String, CodingKey {
                case format
                case sampleRate = "sample_rate"
                case languageHints = "language_hints"
                case vocabulary
                case keepDialect = "keep_dialect"
            }
        }
    }

    struct ResponseBody: Codable {
        struct Output: Codable {
            let text: String?
        }
        struct Usage: Codable {
            let duration: Int?
        }
        let output: Output?
        let usage: Usage?
        let request_id: String?
    }
}
