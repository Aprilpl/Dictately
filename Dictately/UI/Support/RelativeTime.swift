import Foundation

/// 相对时间格式化（SPEC §3 mock 同款：刚刚 / N 分钟前 / 昨天 21:14 / 前天 11:33 / 更早日期）。
/// 纯函数，注入「现在」便于单测。
enum RelativeTime {
    static func string(from date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = now.timeIntervalSince(date)
        let days = daysBetween(date, now, calendar: calendar)
        if interval < 60 { return String(localized: "relative.justNow", bundle: AppResources.bundle) }
        // 分钟/小时档仅限同一自然日内（跨日一律走 昨天/前天/日期，SPEC §3 mock 语义）
        if days == 0 && interval < 3600 {
            let minutes = Int(interval / 60)
            return String(format: String(localized: "relative.minutesAgo", bundle: AppResources.bundle), minutes)
        }
        if days == 0 && interval < 86_400 {
            let hours = Int(interval / 3600)
            return String(format: String(localized: "relative.hoursAgo", bundle: AppResources.bundle), hours)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        if days == 1 {
            formatter.dateFormat = "HH:mm"
            return String(format: String(localized: "relative.yesterdayAt", bundle: AppResources.bundle), formatter.string(from: date))
        }
        if days == 2 {
            formatter.dateFormat = "HH:mm"
            return String(format: String(localized: "relative.dayBeforeYesterdayAt", bundle: AppResources.bundle), formatter.string(from: date))
        }
        // 本年内省年份；跨年带年份
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 完整时间（详情页元数据用）：2026-09-30 21:14。
    static func fullString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func daysBetween(_ earlier: Date, _ later: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: earlier)
        let b = calendar.startOfDay(for: later)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
