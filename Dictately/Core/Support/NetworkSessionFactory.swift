import Foundation

/// 默认 URLSession 工厂（三客户端共用：QwenASRClient / OpenAICompatibleASRClient /
/// OpenAICompatibleClient）——ephemeral（无磁盘缓存，凭据类请求）+ PRD §4 超时预算
/// （request 60s / resource 120s）。三处原为逐字相同的三份副本，2026-10-06 合一；
/// 改超时预算只改这里。
enum NetworkSessionFactory {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }
}
