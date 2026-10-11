import Foundation

/// 使用统计时段（TASK-133）。四段 Tab 的数据形态；区间语义 = 含今天往回 N 个自然日。
enum StatsPeriod: String, CaseIterable {
    case today, week, month, all

    /// 区间起点（Unix 秒）；nil = 全部。today = 今天 0 点；week/month = 含今天
    /// 往回 7/30 个自然日的起点 0 点（本地时区日界由注入的 calendar 决定）。
    func cutoff(now: Date, calendar: Calendar) -> TimeInterval? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now).timeIntervalSince1970
        case .week:
            return startOfDay(daysBack: 6, now: now, calendar: calendar)
        case .month:
            return startOfDay(daysBack: 29, now: now, calendar: calendar)
        case .all:
            return nil
        }
    }

    /// 日均分母（自然日数）；all 动态 = 自首条记录起算（见 compute）。
    var fixedDays: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    private func startOfDay(daysBack: Int, now: Date, calendar: Calendar) -> TimeInterval {
        let day = calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return calendar.startOfDay(for: day).timeIntervalSince1970
    }
}

/// 单个风格的使用计数。count = 全部条目口径（含失败/取消，与听写模式行一致）；
/// pct = count ÷ 区间总条数四舍五入百分比（总条数 0 → nil，视图不显占比）。
struct StyleUsage: Hashable {
    /// 区间内出现过该风格的条目数。
    var styleId: Int64?
    var name: String
    /// 键帽显示串（「⌘ + 1」）；未绑定/存储串非法为 nil。
    var hotkeyDisplay: String?
    var count: Int
    var pct: Int?
    /// 「已删除风格」桶（styleId 为 NULL 或指向已删风格的条目聚合；
    /// name 占位，视图按本标记显示本地化名且不显键帽）。
    var isDeletedBucket = false
}

/// 使用统计聚合（TASK-133，纯函数零 UI 依赖）。口径（2026-10-10/11 三轮裁决）：
/// - 条数类（总条数 / 状态拆分 / 听写模式 / 各风格 / API 推算）= 全部条目；
/// - 时长、字数、速度、日均 = 仅成功条目（失败/取消无产出文本、时长意义弱）；
/// - 字数 = 字符数去空白；总字数取 finalText，口述速度 = rawText 字数 ÷ 录音分钟；
/// - ASR 推算 ≈ 全部落库条目（TASK-130 后转写/润色中取消的 cancelled 条目实际
///   都已发出 ASR 请求；failed 含极少数空 Key 本地拦截属推算误差）；
///   LLM 推算 ≈ 风格条目且 rawText 非空（ASR 成功才走润色；润色中取消计入）；
/// - 日均分母 = 区间自然日（today=1 / week=7 / month=30 / all=自首条起算）。
struct EntryStatistics: Equatable {
    // MARK: 条数（全部条目口径）

    var totalEntries = 0
    var okCount = 0
    var failedCount = 0
    var cancelledCount = 0

    // MARK: 文本（仅成功条目；字符数去空白）

    var totalFinalChars = 0
    var totalRawChars = 0

    // MARK: 时长（仅成功条目；audioDurationMs 缺失计 0）

    var totalDurationMs = 0
    var longestDurationMs = 0

    /// 日均分母（自然日）；空库固定 1（避免除零，「全部」时段无首条可依）。
    var days = 1
    /// 区间内最早条目时间（「全部」Tab 区间文案「yyyy年M月d日至今」用）；空库 nil。
    var firstEntryDate: Date?

    // MARK: 听写 / 风格 / API 推算（全部条目口径）

    var dictationCount = 0
    /// 库内全部风格（含 0 次，按传入 styles 序）+「已删除风格」桶（仅 count>0 出现，尾部）。
    var styleUsage: [StyleUsage] = []
    var asrCalls = 0
    var llmCalls = 0

    // MARK: 派生（展示层直接可用；除零守卫在此）

    var avgDurationMs: Int { okCount > 0 ? totalDurationMs / okCount : 0 }
    /// 口述速度（字/分钟）；无有效录音时长 → nil（视图显「—」）。
    var charsPerMinute: Int? {
        guard totalDurationMs > 0 else { return nil }
        return Int((Double(totalRawChars) * 60_000 / Double(totalDurationMs)).rounded())
    }
    var dailyUsage: Double { days > 0 ? Double(okCount) / Double(days) : 0 }
    var dailyChars: Double { days > 0 ? Double(totalFinalChars) / Double(days) : 0 }

    /// 省时估算（原型同构，2026-10-11 用户裁决）：手打分钟 = raw 字数 ÷ 手打速度
    /// （有内容时至少 1）；口述分钟 = 总时长分钟；省下 = 手打 − 口述（下限 0）。
    /// 三者均用取整后的展示值做减法——括号内「手打 Y − 口述 Z = 省下 X」算术自洽。
    /// 空库（raw 为 0）三值全 0——「省 1 分钟」的假语义不成立（视图层空态也不显横幅）。
    func savedMinutes(typingSpeed: Int) -> (hand: Int, spoke: Int, saved: Int) {
        guard totalRawChars > 0 else { return (0, 0, 0) }
        let speed = max(1, typingSpeed)
        let hand = max(1, Int((Double(totalRawChars) / Double(speed)).rounded()))
        let spoke = Int((Double(totalDurationMs) / 60_000).rounded())
        return (hand, spoke, max(0, hand - spoke))
    }

    // MARK: 聚合入口（纯函数；注入 now/calendar 便于单测钉时区日界）

    static func compute(
        entries: [Entry],
        styles: [Style],
        period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> EntryStatistics {
        var stats = EntryStatistics()
        let cutoff = period.cutoff(now: now, calendar: calendar)
        let inRange: [Entry] = {
            guard let cutoff else { return entries }
            return entries.filter { $0.createdAt >= cutoff }
        }()

        var styleCounts: [Int64?: Int] = [:]
        for entry in inRange {
            stats.totalEntries += 1
            switch entry.status {
            case .success: stats.okCount += 1
            case .failed: stats.failedCount += 1
            case .cancelled: stats.cancelledCount += 1
            }
            stats.asrCalls += 1
            if entry.type == .dictation {
                stats.dictationCount += 1
            } else {
                styleCounts[entry.styleId, default: 0] += 1
                if !(entry.rawText ?? "").isEmpty { stats.llmCalls += 1 }
            }
            guard entry.status == .success else { continue }
            stats.totalFinalChars += nonWhitespaceChars(entry.finalText)
            stats.totalRawChars += nonWhitespaceChars(entry.rawText)
            let ms = entry.audioDurationMs ?? 0
            stats.totalDurationMs += ms
            stats.longestDurationMs = max(stats.longestDurationMs, ms)
        }

        // 日均分母：all = 首条 startOfDay 至今天数 + 1（含首尾两日；空库保持 1）
        if let fixed = period.fixedDays {
            stats.days = fixed
        } else if let earliest = inRange.map(\.createdAt).min() {
            let first = calendar.startOfDay(for: Date(timeIntervalSince1970: earliest))
            let today = calendar.startOfDay(for: now)
            let span = calendar.dateComponents([.day], from: first, to: today).day ?? 0
            stats.days = max(1, span + 1)
            stats.firstEntryDate = Date(timeIntervalSince1970: earliest)
        }

        // 风格行：库内全部风格（0 次照显，展示「暂未使用」）+ 已删除桶（仅 count>0）
        let pctOf: (Int) -> Int? = { count in
            stats.totalEntries > 0
                ? Int((Double(count) / Double(stats.totalEntries) * 100).rounded())
                : nil
        }
        stats.styleUsage = styles.map { style in
            let count = styleCounts[style.id] ?? 0
            return StyleUsage(
                styleId: style.id,
                name: style.name,
                hotkeyDisplay: style.hotkeyCombo.flatMap { HotkeyCombo(storageString: $0)?.displayText },
                count: count,
                pct: pctOf(count))
        }
        let knownIds = Set(styles.compactMap(\.id))
        let deletedCount = styleCounts
            .filter { $0.key == nil || !knownIds.contains($0.key!) }
            .values.reduce(0, +)
        if deletedCount > 0 {
            stats.styleUsage.append(
                StyleUsage(styleId: nil, name: "", hotkeyDisplay: nil, count: deletedCount, pct: pctOf(deletedCount), isDeletedBucket: true))
        }
        return stats
    }

    /// 字符数（去空白：空格/换行/全角空格等 isWhitespace/isNewline 全覆盖）。
    static func nonWhitespaceChars(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.reduce(into: 0) { count, ch in
            if !ch.isWhitespace && !ch.isNewline { count += 1 }
        }
    }
}
