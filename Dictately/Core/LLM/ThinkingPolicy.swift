import Foundation

// MARK: - 推理思考按供应商分派的请求参数（2026-10-04 用户裁决）
//
// 裁决：AI 服务「推理思考」默认关闭且必须真正生效（按各家 API 显式发关闭参数，
// 不再用「省略参数」冒充关闭——多家服务省略时思考默认开启，百炼托管
// deepseek-v4.1 甚至因「思考开 + 非流式」直接 400）；开启 = 各家最低档（低），
// 中/高档位退役。映射依据 docs/LLMDocs 各家文档，明细见
// docs/reasoning-thinking-off-plan.md 第三节。

/// 思考参数集：全 nil = 不携带任何思考参数（字段形态见各家文档）。
struct ThinkingParams: Equatable {
    /// 平铺 reasoning_effort（OpenAI 标准参数）：百炼 qwen 系关闭 = "none"，
    /// OpenAI 关闭 = "none"；开启档统一 "low"。
    var reasoning_effort: String?
    /// 百炼托管 DeepSeek-V4 系的混合思考开关（顶层，非 OpenAI 标准参数）。
    var enable_thinking: Bool?
    /// 智谱 GLM / DeepSeek 官方的 thinking.type（"enabled"/"disabled"）。
    var thinkingType: String?
    /// OpenRouter 扩展 reasoning 对象的 effort 键（开启档 "low"）。
    var openrouterEffort: String?
    /// OpenRouter 扩展 reasoning 对象的 enabled 键（关闭 = false）。
    var openrouterEnabled: Bool?

    init(
        reasoning_effort: String? = nil,
        enable_thinking: Bool? = nil,
        thinkingType: String? = nil,
        openrouterEffort: String? = nil,
        openrouterEnabled: Bool? = nil
    ) {
        self.reasoning_effort = reasoning_effort
        self.enable_thinking = enable_thinking
        self.thinkingType = thinkingType
        self.openrouterEffort = openrouterEffort
        self.openrouterEnabled = openrouterEnabled
    }
}

enum ThinkingPolicy {
    /// 逐家映射（唯一分流点，UI 与客户端不得另立 if）。
    /// - Parameters:
    ///   - provider: 供应商（决定参数形态）。
    ///   - model: 生效模型 ID（大小写不敏感；百炼按是否含 "deepseek"、
    ///     智谱按 "glm-5.3" 前缀分流）。
    ///   - effortLow: 推理思考是否开启（存储值 == "low"）。
    static func params(provider: AppSettings.LLMProvider, model: String, effortLow: Bool) -> ThinkingParams {
        let m = model.lowercased()
        switch provider {
        case .deepseek:
            // 官方端点思考为显式开启（默认真关闭）；开启 = thinking.enabled + low。
            return effortLow
                ? ThinkingParams(reasoning_effort: "low", thinkingType: "enabled")
                : ThinkingParams()
        case .bailian:
            if m.contains("deepseek") {
                // V4 系托管版默认开思考且非流式必须显式关；「开启」结构性不可用
                // （UI 已禁用，此处对遗留 "low" 存量兜底仍发关闭）。
                return ThinkingParams(enable_thinking: false)
            }
            // qwen 系：思考默认开（xhigh），关闭必须显式 reasoning_effort:"none"。
            return effortLow
                ? ThinkingParams(reasoning_effort: "low")
                : ThinkingParams(reasoning_effort: "none")
        case .zhipu:
            if m.hasPrefix("glm-5.3") {
                // 5.3 系思考常开、发 disabled 会报错——只能不携带；开启用 5.3 专属 low。
                return effortLow
                    ? ThinkingParams(reasoning_effort: "low")
                    : ThinkingParams()
            }
            // 其余思考模型（4.7-flash/5.2/…）：enabled 是服务端默认，关闭必须显式 disabled。
            return effortLow
                ? ThinkingParams(thinkingType: "enabled")
                : ThinkingParams(thinkingType: "disabled")
        case .openai:
            // 推理模型默认 medium；关闭 = none（档位值域见 OpenAI 文档 §6）。
            return effortLow
                ? ThinkingParams(reasoning_effort: "low")
                : ThinkingParams(reasoning_effort: "none")
        case .openrouter:
            // 扩展参数为 reasoning 对象（平铺 reasoning_effort 不是其开关形态）。
            return effortLow
                ? ThinkingParams(openrouterEffort: "low")
                : ThinkingParams(openrouterEnabled: false)
        case .opencode:
            // 端点未定义任何思考参数（LLMDocs 全文无 reasoning/thinking）。
            return ThinkingParams()
        case .custom:
            // 任意兼容网关：关闭保守不携带；开启走 OpenAI 兼容标准最低档。
            return effortLow
                ? ThinkingParams(reasoning_effort: "low")
                : ThinkingParams()
        }
    }
}
