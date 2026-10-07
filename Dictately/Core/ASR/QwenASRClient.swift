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

    private let session: URLSession

    /// session 注入供 URLProtocol stub 单测；生产用共享工厂（`NetworkSessionFactory`，
    /// PRD §4 超时预算 request 60s / resource 120s）。
    init(session: URLSession = NetworkSessionFactory.make()) {
        self.session = session
    }

    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript {
        // 0. 空 Key 本地拦截（读文件前）：不发空 Bearer 让服务端 401 兜底——「未配置」与「无效」分开报
        guard !config.apiKey.isEmpty else { throw ASRError.missingApiKey }
        // 0b. scheme 兜底（读文件前）：与 LLM 客户端对称——绕过 UI 的配置
        //     不让 Bearer Key 随非 http(s) scheme 外发（http 为 custom 端点例外）
        guard config.isHTTPScheme else { throw ASRError.invalidBaseURL }

        // 1. 读文件 + 体积预判（Base64 膨胀 4/3）
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            // §11 存储表：音频已清理 → 不可重跑；归 badRequest 携带原因
            //（上游 UI 对音频缺失条目另有「音频已过期清理」禁用态，不走本错误）。
            throw ASRError.badRequest("音频文件读取失败：\(error.localizedDescription)")
        }
        guard fileData.count * 4 / 3 <= Self.encodedSizeLimitBytes else {
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

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")

        // 3. 发请求（计时覆盖编码后→响应，写 entries.asr_latency_ms）
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ASRError.map(error)
        } catch let error as ASRError {
            throw error
        }
        let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        // 4. 状态码映射（§4 错误映射全表）；4xx/5xx body 均落日志——
        // 401（Key 无效）与 400（请求被拒）的区分只能看 body（2026-10-01 排查教训）
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            if http.statusCode >= 500 {
                AppLog.pipeline.error("asr 5xx status=\(http.statusCode, privacy: .public) body=\(summary, privacy: .public)")
            } else {
                AppLog.pipeline.error("asr 4xx status=\(http.statusCode, privacy: .public) body=\(summary, privacy: .public)")
            }
            throw ASRError.map(statusCode: http.statusCode, bodySummary: summary)
        }

        // 5. 解析响应：output 缺失/text 为 nil → badResponse；空串 → emptyResult
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            AppLog.pipeline.error("asr bad response: \(String(decoding: data.prefix(200), as: UTF8.self), privacy: .public)")
            throw ASRError.badResponse
        }
        guard let output = decoded.output else { throw ASRError.badResponse }
        guard let text = output.text else { throw ASRError.badResponse }
        if text.isEmpty { throw ASRError.emptyResult }

        return ASRTranscript(
            text: text,
            durationSeconds: decoded.usage?.duration,
            requestID: decoded.request_id,
            latencyMs: latencyMs
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
