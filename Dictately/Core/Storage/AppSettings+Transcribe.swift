import Foundation

// MARK: - 文件转写（TASK-152；TASK-155 总结设置 v2）

extension AppSettings {
    /// AI 总结 Prompt 预设（TASK-155）：双内置 + 自定义。「会议纪要助理」为默认；
    /// 两套内置文案逐字取自用户 2026-10-25 提供稿（本地化键，勿修正）。
    /// 显示名与内置文案的解析在 FileTranscribeController（本地化键守卫扫描范围）。
    enum SummaryPreset: String, CaseIterable {
        case meeting, expert, custom
    }

    /// 文件转写 AI 总结自定义 Prompt：空串 = 未自定义（custom 预设回落内置文案，
    /// 解析见 FileTranscribeController.resolvedSummaryPrompt）。
    var transcribeSummaryPrompt: String {
        get { string(Key.transcribeSummaryPrompt, default: "") }
        set { defaults.set(newValue, forKey: Key.transcribeSummaryPrompt) }
    }

    /// 总结 Prompt 预设。getter 派生式只读回落（守卫迁移，不写回）：键已存且合法
    /// 用之；否则 TASK-152 存量自定义（transcribeSummaryPrompt trim 非空）→ .custom
    /// （总结行为零突变），从未自定义 → .meeting 新默认（旧「转写助理」单段摘要
    /// 文案已随双内置退役）。首次经设置页保存后显式键落盘，派生不再介入。
    var transcribeSummaryPreset: SummaryPreset {
        get {
            if let raw = defaults.string(forKey: Key.transcribeSummaryPreset),
               let preset = SummaryPreset(rawValue: raw) {
                return preset
            }
            return transcribeSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .meeting : .custom
        }
        set { defaults.set(newValue.rawValue, forKey: Key.transcribeSummaryPreset) }
    }

    /// 总结 AI 服务钉选：nil = 跟随「AI 服务」页当前配置（默认）；非法原始值同跟随。
    /// 钉选家失键时存储保留（总结时走未配置拦截，不自动回退全局）。
    var transcribeSummaryPinnedProvider: LLMProvider? {
        get {
            guard let raw = defaults.string(forKey: Key.transcribeSummaryProvider) else { return nil }
            return LLMProvider(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue ?? "", forKey: Key.transcribeSummaryProvider) }
    }

    /// 钉选家模型下拉预设 ID（快照语义：钉选瞬间取该家「AI 服务」页当前下拉状态；
    /// 空 = 该家当前生效模型）。仅钉选时有意义。
    var transcribeSummaryModel: String {
        get { string(Key.transcribeSummaryModel, default: "") }
        set { defaults.set(newValue, forKey: Key.transcribeSummaryModel) }
    }

    /// 钉选家下拉是否选「自定义模型」（默认 false）。
    var transcribeSummaryUsesCustomModel: Bool {
        get { bool(Key.transcribeSummaryUsesCustomModel, default: false) }
        set { defaults.set(newValue, forKey: Key.transcribeSummaryUsesCustomModel) }
    }

    /// 钉选家自定义模型 ID（默认空；custom 端点供应商的模型输入也绑此键）。
    var transcribeSummaryCustomModelID: String {
        get { string(Key.transcribeSummaryCustomModelID, default: "") }
        set { defaults.set(newValue, forKey: Key.transcribeSummaryCustomModelID) }
    }
}
