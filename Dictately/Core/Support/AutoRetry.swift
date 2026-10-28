import Foundation

/// 网络类错误自动重试一次（TASK-042 / FR-006：立即重试、无退避）的共享骨架。
/// 原三份同款实现（DictationPipeline 转写/润色 + 文件转写）收敛于此；
/// 「哪些错误可重试」「重试之间做什么（日志措辞、计时器重分段）」经参数注入。
/// 与手动重试的区分：手动入口（面板重试/历史重试）走既有 retryFromFailure/retryEntry
/// 并各自记日志；自动重试日志由各调用点的 betweenAttempts 落「auto-retry 1/1」字样。
///
/// Esc 中断（TASK-130）：取消态不重试——重试只会对着已取消的 Task 再抛一次，
/// 还会把「用户主动取消」污染成网络失败路径。
func withAutoRetryOnce<T, RetryError: Error>(
    retryOn: (RetryError) -> Bool,
    betweenAttempts: (RetryError) -> Void,
    operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch let error as RetryError where retryOn(error) {
        guard !Task.isCancelled else { throw CancellationError() }
        betweenAttempts(error)
        return try await operation()
    }
}
