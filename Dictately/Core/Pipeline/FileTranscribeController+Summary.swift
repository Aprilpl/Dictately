import Foundation

/// 总结 Prompt/LLM 解析（TASK-187 文件拆分，行为零变化）。
extension FileTranscribeController {
// MARK: - 总结设置解析（TASK-155；纯函数，聚合层纪律同 §56；TASK-187 迁出）

    /// 总结生效 LLM 解析结果：生效供应商 / 是否跟随全局 / 生效模型。
    struct SummaryLLMResolution: Equatable {
        let provider: AppSettings.LLMProvider
        let isFollow: Bool
        let model: String
    }

    /// 总结 Prompt 生效文案：custom 预设取 trim 后自定义（防御：空回落会议默认——
    /// 保存闸已挡空值，此为 defaults 直写绕过 UI 的兜底）；内置预设逐字内置文案
    /// （不读 transcribeSummaryPrompt）。
    static func resolvedSummaryPrompt(
        preset: AppSettings.SummaryPreset, custom: String
    ) -> String {
        guard preset == .custom else { return preset.builtinPrompt ?? "" }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AppSettings.SummaryPreset.meeting.builtinPrompt ?? "" }
        return trimmed
    }

    /// 总结 LLM 解析（纯函数）：跟随全局（默认）读「AI 服务」页当前供应商与其生效
    /// 模型；钉选家模型 = 自定义 ID 优先，否则快照 ID（空则该家当前生效模型——
    /// 钉选为快照语义，钉选瞬间的值落库，此后不随「AI 服务」页改模型联动）。
    static func resolvedSummaryLLM(settings: AppSettings) -> SummaryLLMResolution {
        if let pinned = settings.transcribeSummaryPinnedProvider {
            let model: String
            if settings.transcribeSummaryUsesCustomModel {
                model = settings.transcribeSummaryCustomModelID
            } else {
                let snapshot = settings.transcribeSummaryModel
                model = snapshot.isEmpty ? settings.llmModel(for: pinned) : snapshot
            }
            return SummaryLLMResolution(provider: pinned, isFollow: false, model: model)
        }
        let global = settings.llmProvider
        return SummaryLLMResolution(
            provider: global, isFollow: true, model: settings.llmModel(for: global))
    }

    /// 总结请求配置：跟随全局 → live；钉选 → 按指定家组装（模型覆写；baseURL 无效
    /// 返回 nil → 调用方走未配置拦截）。
    static func summaryLLMConfig(settings: AppSettings, secrets: SecretStore) -> LLMConfig? {
        let resolution = resolvedSummaryLLM(settings: settings)
        guard !resolution.isFollow else {
            return LLMConfig.live(settings: settings, secrets: secrets)
        }
        return LLMConfig.resolved(
            provider: resolution.provider,
            model: resolution.model,
            settings: settings,
            secrets: secrets)
    }

    /// 自定义 Prompt 态（摘要卡「已自定义」chip）：预设 = custom。
    var summaryUsesCustomPrompt: Bool {
        settingsRef.transcribeSummaryPreset == .custom
    }

    /// 总结设置非默认态（页头「总结设置」蓝点）：预设 ≠ 会议纪要助理，或已钉选服务。
    var summarySettingsCustomized: Bool {
        settingsRef.transcribeSummaryPreset != .meeting
            || settingsRef.transcribeSummaryPinnedProvider != nil
    }

}
