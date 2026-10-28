import Foundation

/// 三个 HTTP 客户端（QwenASR / OpenAICompatibleASR / OpenAICompatible LLM）共享的
/// 「发送 + 传输层每出口记日志 + 错误映射」骨架——此前三份逐行同构（§85 收敛）。
///
/// 覆盖出口：URLSession 抛错（Esc/Task 取消 → CancellationError 直抛，其余 URLError
/// 经 mapURLError 映射）、非 2xx（body 摘要 + mapStatus 映射）。每个出口先补齐
/// RequestLog 再抛错——「每出口必记」（AGENTS §49）在传输层由本类型结构保证；
/// 请求前的本地拦截（空 Key / scheme）与解码后的业务判空出口（text/choices 空等）
/// 仍由各客户端补记。
final class LoggedTransport {
    private let session: URLSession
    /// nil = 不记录（单测默认形态；生产由客户端注入同一实例）。
    private let requestLog: RequestLog?

    init(session: URLSession, requestLog: RequestLog?) {
        self.session = session
        self.requestLog = requestLog
    }

    /// - Parameters:
    ///   - entry: 已组好的日志条目（url/headers/request 齐备）；返回的条目已补
    ///     latencyMs/status，调用方在业务出口继续补记后 append。
    ///   - domainError: 各客户端的领域错误类型（ASRError.self / LLMError.self）——
    ///     传输层若透出该形态错误（理论仅测试 stub 注入可达，URLSession 生产路径
    ///     只抛 URLError 族；QwenASRClient TASK-016 初版兜底分支的保真迁移），
    ///     记日志后原样上抛。
    ///   - mapURLError: URLError → 领域错误（ASRError.map / LLMError.map）。
    ///   - mapStatus: (statusCode, bodySummary) → 领域错误（各家 .map(statusCode:bodySummary:)）。
    ///   - logHTTPError: 非 2xx 的 AppLog 措辞（ASR 两客户端分 4xx/5xx 两行、LLM 单行）。
    /// - Returns: 2xx 响应体 + 补齐计时/状态的日志条目（业务解码与判空在调用方继续）。
    func send<DomainError: Error>(
        _ request: URLRequest,
        entry: RequestLog.Entry,
        domainError: DomainError.Type,
        mapURLError: (URLError) -> Error,
        mapStatus: (Int, String) -> Error,
        logHTTPError: (Int, String) -> Void
    ) async throws -> (Data, RequestLog.Entry) {
        var log = entry
        let data: Data
        let response: URLResponse
        let startedAt = Date()
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            // Esc 中断（TASK-130）：取消抛 CancellationError 而非映射 networkUnreachable
            // ——否则管道 autoRetryOnce 会二发、失败收口会覆盖已取消的面板/条目状态。
            // 日志照落（§49 每出口必记），outcome 标「已取消」与真实网络错误区分。
            if error.code == .cancelled {
                log.error = "已取消（Esc 中断，请求未完成）"
                requestLog?.append(log)
                throw CancellationError()
            }
            log.error = "网络错误：\(error.localizedDescription)"
            requestLog?.append(log)
            throw mapURLError(error)
        } catch is CancellationError {
            // Task 协作取消的直接形态（URLSession async 新版可能不经 URLError 包装）
            log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            log.error = "已取消（Esc 中断，请求未完成）"
            requestLog?.append(log)
            throw CancellationError()
        } catch let error as DomainError {
            log.error = "\(error)"
            requestLog?.append(log)
            throw error
        }
        log.latencyMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        if let http = response as? HTTPURLResponse { log.status = http.statusCode }

        // 4xx/5xx body 均落日志——401（Key 无效）与 400（请求被拒）的区分只能看 body
        //（2026-10-01 排查教训；§8 错误映射全表）
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let summary = String(decoding: data.prefix(200), as: UTF8.self)
            logHTTPError(http.statusCode, summary)
            log.error = "HTTP \(http.statusCode)"
            log.bodySummary = summary
            requestLog?.append(log)
            throw mapStatus(http.statusCode, summary)
        }
        return (data, log)
    }
}
