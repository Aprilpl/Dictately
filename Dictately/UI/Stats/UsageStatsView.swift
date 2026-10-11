import SwiftUI

/// 使用统计页（TASK-133，原型 docs/design-demos/usage-stats.html 三轮定稿）：
/// 四段 Tab（今天/7 天/30 天/全部）+ hero 汇总卡（总字数/录音总时长/语音条数/
/// 平均口述速度）+ 省时估算横幅（「省下 X（手打 Y − 口述 Z）」，手打速度 10–200
/// 可调并持久化）+ 三张分组卡（语音与文本 / 听写与风格 / 工作模式分布——API 调用
/// 推算第一行 + 本地模型「0 次·暂未开放」第二行）+ 口径脚注。
/// 数据 = onAppear/切 Tab 现算（EntryStatistics 纯函数聚合 entries 表，量级毫秒）；
/// 布局照 GeneralSettingsView 三明治（内容列 800 居中 / 值列 230 左对齐）。
struct UsageStatsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var period: StatsPeriod = .week
    @State private var stats: EntryStatistics?
    @State private var loadFailed = false
    /// 手打速度本地镜像（bug00013 规则：AppSettings 非 Observable，banner 数字与
    /// 输入框必须由 @State 驱动重绘；写入时双写 settings 持久化）。
    @State private var typingSpeed = 40

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if loadFailed {
                    NoticeBanner(title: "usage.loadFailed", tone: .warn)
                        .padding(.top, 12)
                }
                tabRow
                if let stats, stats.totalEntries > 0 {
                    statsContent(stats)
                } else if !loadFailed {
                    emptyState
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 48)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            typingSpeed = environment.settings.statsTypingSpeed
            reload()
        }
        .onChange(of: period) { _, _ in reload() }
    }

    // MARK: - 数据

    private func reload() {
        let calendar = Calendar.current
        let now = Date()
        do {
            let entries = try environment.entryRepository.fetchAll(
                since: period.cutoff(now: now, calendar: calendar))
            let styles = try environment.styleRepository.fetchAll()
            stats = EntryStatistics.compute(
                entries: entries, styles: styles, period: period, now: now, calendar: calendar)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.pipeline.error("usage stats reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 页头 / Tab / 区间

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("usage.title")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(Theme.text1)
            Text("usage.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(4)
        }
        .padding(.bottom, 10)
    }

    private var tabRow: some View {
        HStack(spacing: 14) {
            GlassSegmented(
                options: StatsPeriod.allCases,
                selection: $period,
                small: true,
                label: { $0.title })
            if let stats, stats.totalEntries > 0 {
                Text(rangeLine(stats))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
            }
        }
        .padding(.top, 24)
    }

    /// 区间说明行（今天「M月d日」/ 区间「M月d日 – M月d日 · N 天」/ 全部「yyyy年M月d日
    /// 至今 · N 天」）。日期字面量格式沿 RelativeTime 的 dateFormat 先例（中文单语言）。
    private func rangeLine(_ s: EntryStatistics) -> String {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .today:
            return shortDate(now)
        case .week, .month:
            let start = Date(timeIntervalSince1970: period.cutoff(now: now, calendar: calendar) ?? 0)
            return "\(shortDate(start)) – \(shortDate(now)) · \(period.fixedDays ?? 0) 天"
        case .all:
            guard let first = s.firstEntryDate else { return "" }
            return "\(longDate(first))至今 · \(s.days) 天"
        }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    // MARK: - 统计主体

    private func statsContent(_ s: EntryStatistics) -> some View {
        Group {
            heroCard(s)
            savedBanner(s)
            sectionLabel("usage.section.base", topPadding: 24)
            SettingsCard {
                SettingRow("usage.row.breakdown", hint: "usage.row.breakdown.hint") {
                    statValue("\(s.okCount) / \(s.failedCount) / \(s.cancelledCount)")
                }
                SettingRow("usage.row.longest") {
                    statValue(PanelFormat.recordingClock(ms: s.longestDurationMs))
                }
                SettingRow("usage.row.avg") {
                    statValue(PanelFormat.recordingClock(ms: s.avgDurationMs))
                }
                SettingRow(
                    title: String(localized: "usage.row.daily.count"),
                    hint: dailyHint(String(localized: "usage.row.daily.count.days"),
                                    today: String(localized: "usage.row.daily.today"))) {
                    statValue(String(format: String(localized: "usage.row.perDay"), Self.fmtDouble(s.dailyUsage)))
                }
                SettingRow(
                    title: String(localized: "usage.row.daily.chars"),
                    hint: dailyHint(String(localized: "usage.row.daily.chars.days"),
                                    today: String(localized: "usage.row.daily.today")),
                    divider: false) {
                    statValue(String(format: String(localized: "usage.row.charsPerDay"), Self.fmtDouble(s.dailyChars)))
                }
            }

            sectionLabel("usage.section.styles", topPadding: 36)
            SettingsCard {
                SettingRow(title: String(localized: "usage.row.dictation")) {
                    statValue(timesText(s.dictationCount), sub: pctText(pct(s.dictationCount)))
                }
                ForEach(Array(s.styleUsage.enumerated()), id: \.element) { index, usage in
                    styleRow(usage, divider: index != s.styleUsage.count - 1)
                }
            }

            sectionLabel("usage.section.mode", topPadding: 36)
            SettingsCard {
                SettingRow("usage.row.api", hint: "usage.row.api.hint") {
                    statValue(
                        timesText(s.asrCalls + s.llmCalls),
                        sub: String(format: String(localized: "usage.row.api.sub"), s.asrCalls, s.llmCalls))
                }
                SettingRow("usage.row.local", hint: "usage.row.local.hint", divider: false) {
                    statValue(String(localized: "usage.row.local.zero"), sub: String(localized: "usage.row.local.sub"))
                }
            }

            Text("usage.footnote")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
                .padding(.top, 14)
        }
    }

    private func sectionLabel(_ key: LocalizedStringKey, topPadding: CGFloat) -> some View {
        Text(key)
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.top, topPadding)
            .padding(.bottom, 16)
    }

    /// 日均两行 hint：今天 Tab 显「今天时段即当日值」（口径裁决），其余按天数。
    private func dailyHint(_ daysFormat: String, today: String) -> String? {
        period == .today ? today : String(format: daysFormat, stats?.days ?? 1)
    }

    // MARK: - Hero 汇总卡（四列大数字 + 竖分隔线）

    private func heroCard(_ s: EntryStatistics) -> some View {
        // 原型 .hero{margin-top:16px}——外层 VStack spacing 0，不垫 16 会把汇总卡
        // 直接贴上筛选行（分段控件与卡片边框贴死，用户红框反馈）
        SettingsCard {
            HStack(spacing: 0) {
                heroCol(value: Self.fmtInt(s.totalFinalChars), unitKey: "usage.unit.chars", labelKey: "usage.hero.chars")
                heroDivider
                heroCol(value: PanelFormat.recordingClock(ms: s.totalDurationMs), unitKey: "usage.unit.ms", labelKey: "usage.hero.duration")
                heroDivider
                heroCol(value: Self.fmtInt(s.totalEntries), unitKey: "usage.unit.times", labelKey: "usage.hero.entries")
                heroDivider
                heroCol(value: s.charsPerMinute.map(Self.fmtInt) ?? "—", unitKey: "usage.unit.cpm", labelKey: "usage.hero.speed")
            }
            .padding(.vertical, 16)
        }
        .padding(.top, 16)
    }

    private func heroCol(value: String, unitKey: LocalizedStringKey, labelKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(Theme.text1)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unitKey)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Text(labelKey)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private var heroDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 0.5)
    }

    // MARK: - 省时估算横幅（手打速度可调，持久化）

    private func savedBanner(_ s: EntryStatistics) -> some View {
        let saved = s.savedMinutes(typingSpeed: typingSpeed)
        return HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ok)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("usage.saved.prefix")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
                Text(Self.fmtMinutes(saved.saved))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text(String(format: String(localized: "usage.saved.detail"),
                            Self.fmtMinutes(saved.hand), Self.fmtMinutes(saved.spoke)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text("usage.saved.speed")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                SpeedField(speed: speedBinding)
                Text("usage.saved.speedUnit")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.greenTintBg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.greenTintBorder, lineWidth: 1))
        .padding(.top, 12)
    }

    /// 双写：@State 驱动本视图重绘（banner 即时重算），settings 承担持久化。
    private var speedBinding: Binding<Int> {
        Binding(
            get: { typingSpeed },
            set: {
                typingSpeed = $0
                environment.settings.statsTypingSpeed = $0
            })
    }

    // MARK: - 风格行（标题 = 风格名 + 键帽 chip，SettingRow 不支持组合标题故手写同规格行）

    private func styleRow(_ usage: StyleUsage, divider: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Text(usage.isDeletedBucket ? String(localized: "usage.row.style.deleted") : usage.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text1)
                if let key = usage.hotkeyDisplay, !usage.isDeletedBucket {
                    Chip(text: key, font: Theme.mono(11.5))
                }
            }
            Spacer(minLength: 12)
            statValue(
                timesText(usage.count),
                sub: usage.count == 0
                    ? String(localized: "usage.row.style.unused")
                    : pctText(usage.pct))
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if divider { Divider().overlay(Theme.line) } }
    }

    // MARK: - 值列（230 左对齐块，与各设置页同款；主值 13.5 t1 + 副值 12 t3 上下排）

    private func statValue(_ main: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(main)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
            if let sub {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
            }
        }
        .frame(width: 230, alignment: .leading)
    }

    private func timesText(_ count: Int) -> String {
        String(format: String(localized: "usage.row.timesUnit"), count)
    }

    private func pct(_ count: Int) -> Int? {
        guard let stats, stats.totalEntries > 0 else { return nil }
        return Int((Double(count) / Double(stats.totalEntries) * 100).rounded())
    }

    private func pctText(_ value: Int?) -> String? {
        value.map { String(format: String(localized: "usage.row.pct"), $0) }
    }

    // MARK: - 空态（新装机 / 本时段无数据）

    private var emptyState: some View {
        VStack(spacing: 14) {
            WaveformView(isActive: false, sample: { nil }, barHeight: 20)
            Text("usage.empty")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Text("usage.empty.desc")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .padding(.bottom, 24)
    }

    // MARK: - 数字格式化（页面局部；聚合层只出原始值）

    /// 千分位整数（4,615 / 17,934）。
    static func fmtInt(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// 分钟数中文形态：0 分钟 / N 分钟 / N 小时 / N 小时 M 分钟（措辞统一带「钟」）。
    static func fmtMinutes(_ minutes: Int) -> String {
        if minutes <= 0 { return String(localized: "usage.saved.zeroMinutes") }
        if minutes < 60 { return String(format: String(localized: "usage.saved.minutes"), minutes) }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return String(format: String(localized: "usage.saved.hours"), hours) }
        return String(format: String(localized: "usage.saved.hourMinutes"), hours, rest)
    }

    /// 日均类数值：整数显整数（10），非整数一位小数（4.9）。
    static func fmtDouble(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

extension StatsPeriod {
    /// 分段控件文案（GlassSegmented 需纯 String）。
    var title: String {
        switch self {
        case .today: return String(localized: "usage.tab.today")
        case .week: return String(localized: "usage.tab.week")
        case .month: return String(localized: "usage.tab.month")
        case .all: return String(localized: "usage.tab.all")
        }
    }
}

/// 手打速度输入框（横幅右缘，54pt 宽数字框）：**点击编辑式**（2026-10-11 用户追裁，
/// 覆盖原型常显边框形态）——平时只显纯文本数字（与周围标签同排无边框），点击才
/// 出现文本框（自动聚焦预填）；输入即时钳定（10–200 合法才写 binding，越界红边
/// 不写）；失焦/回车恢复为当前合法值并退出编辑态回纯文本——与原型交互同构后按追裁演进。
private struct SpeedField: View {
    @Binding var speed: Int
    @State private var editing = false
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        if editing {
            editor
        } else {
            Text("\(speed)")
                .font(Theme.mono(12.5))
                .monospacedDigit()
                .foregroundStyle(hovering ? Theme.text1 : Theme.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture {
                    text = String(speed)
                    invalid = false
                    editing = true
                    focused = true
                }
        }
    }

    private var editor: some View {
        TextField("40", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(12.5))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 54)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FieldBackground())
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, lineWidth: 1))
            .focused($focused)
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let value = Int(trimmed) else {
                    invalid = false // 清空重输的中间态不标红
                    return
                }
                let legal = (10...200).contains(value)
                invalid = !legal
                if legal { speed = value }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    text = String(speed) // 恢复为当前合法值（越界/残留文本一并清）
                    invalid = false
                    editing = false // 失焦即回纯文本（隐藏式核心：框只在编辑期存在）
                }
            }
    }

    private var borderColor: Color {
        if focused { return Theme.blueTintBorder }
        return invalid ? Theme.redTintBorder : .clear
    }
}
