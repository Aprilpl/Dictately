import Foundation

// MARK: - 值类型（页面选择 / 待转文件 / 运行队列条目；TASK-187 从控制器迁出）

/// 总结 Prompt 预设的展示层解析（TASK-155；置于本文件 = 本地化键守卫扫描范围，
/// §68 纪律）。两套内置文案逐字取自用户 2026-10-25 提供货，键值勿修正。
extension AppSettings.SummaryPreset {
    /// 显示名（分段控件 / 摘要卡来源注）。
    var displayName: String {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.preset.meeting")
        case .expert: return String(localized: "transcribe.summary.preset.expert")
        case .custom: return String(localized: "transcribe.summary.preset.custom")
        }
    }

    /// 内置文案（custom 无内置 → nil）。
    var builtinPrompt: String? {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.prompt.meeting")
        case .expert: return String(localized: "transcribe.summary.prompt.expert")
        case .custom: return nil
        }
    }

    /// 职能副行（分段控件下方 desc；编辑器 fork 提示另见视图层）。
    var roleDescription: String {
        switch self {
        case .meeting: return String(localized: "transcribe.summary.preset.meeting.desc")
        case .expert: return String(localized: "transcribe.summary.preset.expert.desc")
        case .custom: return String(localized: "transcribe.summary.preset.custom.desc")
        }
    }
}

/// 文件转写页面级模型选择（方案 D「转写模型」节）：页面独立，**不写回全局设置**——
/// 默认值取全局当前生效（asrMode + 当前供应商/本地模型），切换仅影响本页转写。
struct TranscribeModelSelection: Equatable {
    var mode: AppSettings.ASRMode
    /// mode == .api 时生效的供应商。
    var apiProvider: AppSettings.ASRProvider
    /// mode == .local 时生效的本地模型 repo id（nil = 本地无可选）。
    var localRepoID: String?

    /// 全局当前生效的快照（页面默认值）。
    static func current(settings: AppSettings) -> TranscribeModelSelection {
        TranscribeModelSelection(
            mode: settings.asrMode,
            apiProvider: settings.asrProvider,
            localRepoID: settings.activeLocalModel)
    }
}

/// 待转文件（picked 态工作台列表项；开始转写后随批次快照进队列）。
struct PendingTranscribeFile: Identifiable {
    let id = UUID()
    /// 原文件 URL（导入前展示用；转写时经 audioStore.copyImport 拷贝入库）。
    let url: URL
    let fileName: String
    let ext: String
    let sizeBytes: Int64
    /// 异步探测回填（探测中 nil → UI 显示「—」）。
    var durationMs: Int?
}

/// 运行队列条目（running 态左栏队列；与 DB 行一一对应，dbID 在插行后回填）。
struct TranscribeQueueItem: Identifiable {
    enum State: Equatable {
        case waiting, running, succeeded, failed
    }

    let id = UUID()
    /// 对应 file_transcripts 行（插入后回填）。
    var dbID: Int64?
    let fileName: String
    let ext: String
    var state: State = .waiting
    /// 分段真进度 0…1（TASK-151：已完成段/总段数，段循环直写；完成跳 1）。
    var progress: Double = 0
    /// 当前段序号/总段数（running 态「分段 x/N」标签；分段前 nil）。
    var sliceIndex: Int?
    var sliceCount: Int?
    /// 转写耗时预估（秒；分段循环用已测单片均值×剩余段实时更新）。
    /// 本条已用秒在控制器 `itemElapsedSeconds`（旁路字典——ticker 每 1s 写它，
    /// queueItems 只在真进度/状态变化时失效，视图依赖粒度下沉配套，TASK-158）。
    var estimateSeconds: Double = 10
    var startedAt: Date?
    var errorMessage: String?
    /// 失败分类（ASRError.kindKey / cancelled / importFailed）。
    var errorKind: String?
}

