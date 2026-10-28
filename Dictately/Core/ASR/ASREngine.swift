import Foundation

/// 转写结果（PRD §4 契约 A 响应字段 + FR-004 计时要求）。
struct ASRTranscript: Equatable {
    /// 完整识别文本（output.text）。
    let text: String
    /// usage.duration——服务端识别的音频时长（秒），仅入库参考。
    let durationSeconds: Int?
    /// request_id——排查 5xx 用（§11：记录日志）。
    let requestID: String?
    /// 请求耗时（毫秒），写 entries.asr_latency_ms。
    let latencyMs: Int
}

/// 转写引擎协议（PRD §2/§7：引擎层协议化，供应商替换不动业务层；
/// 本地模型（v1 后）实现同一协议即可接入）。
protocol ASREngine: AnyObject {
    /// 转写指定音频文件。实现负责：体积预判 → 编码 → 请求 → 错误分类 → 计时。
    /// - Throws: ASRError（全分类见 ASRError.swift）。
    func transcribe(audioFileAt url: URL, config: ASRConfig) async throws -> ASRTranscript
}
