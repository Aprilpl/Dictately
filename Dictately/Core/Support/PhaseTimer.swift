import CryptoKit
import Foundation

/// 阶段计时器（PRD FR-006）：记录一次听写各阶段耗时并输出一条结构化日志行。
/// 阶段固定六个：hotkey→panel、record、encode、asr、llm、paste。
///
/// 隐私红线（PRD §7 Security）：日志只含毫秒数与文本摘要（长度 + SHA256 前 8 位），
/// **绝不包含转写文本内容**——Pipeline 各阶段禁止自行拼日志文本，统一走 `textDigest`。
final class PhaseTimer {
    /// FR-006 定义的阶段；rawValue 即日志行中的展示名。
    enum Phase: String, CaseIterable, Codable, Hashable {
        case hotkeyToPanel = "hotkey→panel"
        case record
        case encode
        case asr
        case llm
        case paste
    }

    /// 时钟（返回毫秒，单调递增即可）；测试注入假时钟精确断言。
    private let now: () -> Double
    private var startedAt: [Phase: Double] = [:]
    /// 已结束阶段的毫秒数（begin 未配对的阶段不计入）。
    private(set) var durationsMs: [Phase: Int] = [:]

    /// 默认用系统单调时钟（DispatchTime.uptime，不受墙钟调整影响）。
    init(clock: (() -> Double)? = nil) {
        if let clock {
            now = clock
        } else {
            now = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
        }
    }

    // MARK: - 计时

    /// 开始计阶段（重复 begin 同一阶段按最后一次起算）。
    func begin(_ phase: Phase) {
        startedAt[phase] = now()
    }

    /// 结束阶段并落毫秒数；未 begin 的 end 视为无效调用（忽略，不崩溃）。
    func end(_ phase: Phase) {
        guard let start = startedAt.removeValue(forKey: phase) else { return }
        durationsMs[phase] = max(0, Int((now() - start).rounded()))
    }

    /// 清零（复用同一实例跑下一次听写前调用）。
    func reset() {
        startedAt.removeAll()
        durationsMs.removeAll()
    }

    // MARK: - 汇总输出

    /// 结构化汇总行（固定阶段顺序、仅含已计时阶段，total 为各阶段之和）：
    /// `⏱ phases: hotkey→panel=12ms record=3400ms asr=1210ms total=4622ms`
    var summaryLine: String {
        let parts = Phase.allCases.compactMap { phase -> String? in
            guard let ms = durationsMs[phase] else { return nil }
            return "\(phase.rawValue)=\(ms)ms"
        }
        let total = durationsMs.values.reduce(0, +)
        return "⏱ phases: \(parts.joined(separator: " ")) total=\(total)ms"
    }

    /// 输出汇总日志（pipeline category，notice 级持久化）并 reset；返回日志行供测试断言。
    @discardableResult
    func finish() -> String {
        let line = summaryLine
        AppLog.pipeline.notice("dictation \(line, privacy: .public)")
        reset()
        return line
    }

    // MARK: - 文本摘要（隐私安全）

    /// 转写文本摘要（PRD §7）：仅长度 + SHA256 前 8 位十六进制。
    /// 示例：`len=5 sha256=2cf24dba`。日志中引用文本一律用它，禁止原文。
    static func textDigest(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "len=\(text.utf8.count) sha256=\(prefix)"
    }
}
