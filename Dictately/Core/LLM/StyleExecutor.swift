import Foundation

/// 风格执行器（PRD FR-009/§4 契约 B 的业务封装）：
/// 风格 Prompt → system/user 双消息组装 → LLM 调用 → 结果语义化。
final class StyleExecutor {
    private let engine: LLMEngine

    init(engine: LLMEngine) {
        self.engine = engine
    }

    /// 组装 system/user 双消息（2026-10-04 智谱 1214 修复：仅 system 单消息被
    /// 「messages 参数非法」拒绝——七家 LLMDocs 示例均为 system+user 形态）：
    /// system = 风格模板**原文**（`{text}` 占位符原样保留——逐字纪律不拆不删，
    /// 占位符即「转写文本槽位」标记）；user = 原始转写文本。无占位符的模板同
    /// 规则（旧 composePrompt「追加文末」回退语义由双消息形态等价承担，FR-009）。
    static func composeMessages(stylePrompt: String, rawText: String) -> (system: String, user: String) {
        (stylePrompt, rawText)
    }

    /// 以指定风格润色原始转写。返回 trim 后文本（LLM 客户端负责 trim）。
    func polish(rawText: String, style: Style, config: LLMConfig) async throws -> LLMResult {
        let messages = Self.composeMessages(stylePrompt: style.prompt, rawText: rawText)
        return try await engine.complete(system: messages.system, user: messages.user, config: config)
    }
}
