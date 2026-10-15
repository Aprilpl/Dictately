import Foundation

/// OpenAI 兼容 Chat Completions 客户端（PRD §4 契约 B 逐字实现）。
///
/// 请求：POST {baseURL}/chat/completions
/// Headers：Authorization Bearer、Content-Type application/json
/// Body：{"model":…, "messages":[{"role":"system",…},{"role":"user",…}],
///       "temperature":0.3, "stream":false}
/// messages 为 system+user 双消息（2026-10-04 智谱 1214 修复：system-only 单消息
/// 被「messages 参数非法」拒绝；双消息是七家 LLMDocs 示例一致的标准形态）。
///
/// 错误映射：连接/超时→networkUnreachable/timeout；401→invalidApiKey；429→rateLimited；
/// 5xx→serverError；choices 空/content 空→emptyResult；非 JSON→badResponse；
/// 非 https baseURL 直接拒绝（invalidBaseURL，§7 安全要求）。
final class OpenAICompatibleClient: LLMEngine {
    private let session: URLSession
    /// 请求日志（nil = 不记录：单测默认形态；生产由 AppEnvironment 注入）。
    private let requestLog: RequestLog?

    init(session: URLSession = NetworkSessionFactory.make(), requestLog: RequestLog? = nil) {
        self.session = session
        self.requestLog = requestLog
    }

    func complete(system: String, user: String, config: LLMConfig) async throws -> LLMResult {
        let body = makeBody(
            system: system,
            user: user,
            config: config
        )
        let startedAt = Date()
        let content = try await post(body: body, config: config, purpose: .polish)
        let latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        return LLMResult(text: content, model: config.model, latencyMs: latencyMs)
    }

    func testConnection(config: LLMConfig) async throws -> Int {
        let startedAt = Date()
        let body = makeBody(
            system: "",
            user: "ping",
            config: config,
            maxTokens: 1
        )
        // 探测请求 max_tokens=1：服务端常返回空 content（首 token 被截/推理模型全耗在
        // reasoning 上）。连通性只要求 200 + 合法 JSON + choices 非空，不检查内容——
        // 否则把健康连接误报成「润色返回为空」。
        _ = try await post(body: body, config: config, requireContent: false, purpose: .test)
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - 私有

    /// 请求体统一构造（complete / testConnection 共用，思考参数经
    /// ThinkingPolicy 分派后填入——字段形态逐家不同，见 ThinkingPolicy.swift）。
    /// messages：system 非空时 [system, user]，空则仅 [user]（不产出空 system 消息）。
    private func makeBody(
        system: String,
        user: String,
        config: LLMConfig,
        maxTokens: Int? = nil
    ) -> RequestBody {
        let t = config.thinkingParams
        var messages: [RequestBody.Message] = []
        if !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: user))
        return RequestBody(
            model: config.model,
            messages: messages,
            temperature: config.temperature,
            reasoning_effort: t.reasoning_effort,
            enable_thinking: t.enable_thinking,
            thinking: t.thinkingType.map { .init(type: $0) },
            // 两键全 nil 时必须整体传 nil——可选属性 nil 虽不编码，但非 nil 的
            // 空 ReasoningBody 仍会产出 "reasoning":{} 发给所有供应商。
            reasoning: (t.openrouterEffort != nil || t.openrouterEnabled != nil)
                ? ReasoningBody(effort: t.openrouterEffort, enabled: t.openrouterEnabled)
                : nil,
            stream: false,
            max_tokens: maxTokens
        )
    }

    /// - Parameters:
    ///   - requireContent: true（正式润色）= content 缺失/空串按错误处理；
    ///     false（测试连接）= 有合法 choices 即成功。
    ///   - purpose: 请求日志用途标签（润色 / 测试连接）。
    private func post(
        body: RequestBody,
        config: LLMConfig,
        requireContent: Bool = true,
        purpose: RequestLog.Entry.Purpose
    ) async throws -> String {
        let bodyData = try JSONEncoder().encode(body)
        // 请求日志形态的请求体：与实发字节同源（编码后再解回对象，杜绝两套构造漂移）
        let loggedBody = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]

        guard config.isHTTPScheme else {
            requestLog?.append(.rejected(
                kind: .llm, purpose: purpose,
                url: config.endpoint.absoluteString, request: loggedBody,
                error: "invalidBaseURL（本地拦截，未发请求）"))
            throw LLMError.invalidBaseURL
        }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // 端点附加头（OpenCode 稳定会话头 x-opencode-session 等，见 LLMConfig.extraHTTPHeaders）
        for (name, value) in config.extraHTTPHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // 请求日志条目：Authorization 脱敏（明文 Key 绝不落盘），随请求推进补齐 outcome
        var log = RequestLog.Entry(
            kind: .llm,
            purpose: purpose,
            url: config.endpoint.absoluteString,
            headers: RequestLog.loggedHeaders(
                authorization: RequestLog.redactedAuthorization(apiKey: config.apiKey),
                contentType: "application/json",
                extra: config.extraHTTPHeaders),
            request: loggedBody)

        let data: Data
        let response: URLResponse
        let startedAt = Date()
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            // Esc 中断（TASK-130）：取消抛 CancellationError 而非映射 networkUnreachable
            // ——否则管道 polishWithAutoRetry 会二发、失败收口会覆盖已取消的面板/条目状态
            if error.code == .cancelled {
                log.error = "已取消（Esc 中断，请求未完成）"
                requestLog?.append(log)
                throw CancellationError()
            }
            log.error = "网络错误：\(error.localizedDescription)"
            requestLog?.append(log)
            throw LLMError.map(error)
        } catch is CancellationError {
            log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            log.error = "已取消（Esc 中断，请求未完成）"
            requestLog?.append(log)
            throw CancellationError()
        }
        log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        if let http = response as? HTTPURLResponse { log.status = http.statusCode }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 4xx/5xx 一律落 status + body 摘要（与 ASR 两客户端对齐，AGENTS §8 裁决；
            // 2026-10-02 用户排 OpenCode 400 时实锤 LLM 侧此前只记 5xx 的盲区）
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            AppLog.pipeline.error("llm http status=\(http.statusCode, privacy: .public) body=\(summary, privacy: .public)")
            log.bodySummary = summary
            log.error = "HTTP \(http.statusCode)"
            requestLog?.append(log)
            throw LLMError.map(statusCode: http.statusCode, bodySummary: summary)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            AppLog.pipeline.error("llm bad response: \(summary, privacy: .public)")
            log.error = "响应非 JSON"
            log.bodySummary = summary
            requestLog?.append(log)
            throw LLMError.badResponse
        }
        guard let choices = decoded.choices, !choices.isEmpty else {
            log.error = "choices 为空（emptyResult）"
            requestLog?.append(log)
            throw LLMError.emptyResult
        }
        if !requireContent {
            requestLog?.append(log) // 测试连接：服务应答正常即连通
            return ""
        }
        guard let content = choices[0].message?.content else {
            log.error = "content 缺失（badResponse）"
            requestLog?.append(log)
            throw LLMError.badResponse
        }
        if content.isEmpty {
            log.error = "content 为空（emptyResult）"
            requestLog?.append(log)
            throw LLMError.emptyResult
        }
        requestLog?.append(log)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 契约 B 的 Codable 镜像（字段名逐字）

private extension OpenAICompatibleClient {
    struct RequestBody: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        /// nil = 不携带（服务端默认；v2-glass AI 服务页「空为默认」语义）。
        var temperature: Double?
        /// reasoning_effort（OpenAI 标准参数；百炼 qwen 系关闭 = "none"）。
        var reasoning_effort: String?
        /// 百炼托管 DeepSeek-V4 系混合思考开关（顶层非标参数）；nil = 不携带。
        var enable_thinking: Bool?
        /// DeepSeek 官方的思考开关 {"type": enabled|disabled}；nil = 不携带。
        var thinking: ThinkingBody?
        /// OpenRouter 扩展 reasoning 对象（{"effort":…} / {"enabled":false}）；
        /// 两键全 nil = 不携带。
        var reasoning: ReasoningBody?
        let stream: Bool
        var max_tokens: Int?
    }

    struct ThinkingBody: Codable {
        let type: String
    }

    /// 两键全 nil 时整体省略（OpenRouter 关闭/开启二选一，不会同时出现）。
    struct ReasoningBody: Codable {
        var effort: String?
        var enabled: Bool?
    }

    struct ResponseBody: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String?
            }
            let message: Message?
        }
        let choices: [Choice]?
    }
}
