import SwiftUI
import AppKit

// MARK: - 双主题令牌（TASK-038：design-demos/v2-glass.html glassTokens 逐项转录）
//
// 视觉基准：`design-demos/v2-glass.html`（glassTokens/glassStyles 浅/深双主题）+ SPEC §4 色彩协议。
// 全部颜色集中于此文件（AGENTS.md 硬约束 #3：UI 代码禁止新增硬编码颜色）。
// 动态色经 NSColor dynamicProvider 实现——随系统/NSApp.appearance 切换即时生效。

/// 主题令牌与外观接线。颜色命名对齐 v2-glass.html 的 glassTokens 键名，便于逐项核对。
enum Theme {

    // MARK: 动态色构造

    /// 浅/深两值动态色（唯一合法的 UI 颜色来源；本文件以外禁止再出现 Color 字面量）。
    static func dyn(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgba(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        rgb(hex).withAlphaComponent(alpha)
    }

    // MARK: 品牌与语义色（SPEC §4：品牌蓝仅极小面积点睛；红/绿为小面积语义色）

    /// 品牌电光蓝 #029cfa（选中态/focus ring/录音指示等点睛）。
    static let blue = dyn(light: rgb(0x029cfa), dark: rgb(0x029cfa))
    /// 录音红 #ff453a（录音中指示、危险动作）。
    static let red = dyn(light: rgb(0xff453a), dark: rgb(0xff453a))
    /// 状态绿（开态拨杆/成功）#30d158。
    static let green = dyn(light: rgb(0x30d158), dark: rgb(0x30d158))
    /// 橙 #ff9f0a（警示横幅等小面积）。
    static let orange = dyn(light: rgb(0xff9f0a), dark: rgb(0xff9f0a))

    // MARK: 文字灰阶（浅底 #1e2528 系 / 深底 #e8ecee 系）

    /// 一级文字 t1。
    static let text1 = dyn(light: rgb(0x1e2528), dark: rgb(0xe8ecee))
    /// 二级文字 t2。
    static let text2 = dyn(light: rgb(0x454f54), dark: rgb(0xa8b1b5))
    /// 三级文字/注脚 t3。
    static let text3 = dyn(light: rgb(0x5c666a), dark: rgb(0x9aa4a8))
    /// 数字（计时/延迟/计数）——色同 t1，配 SF Mono + tabular-nums（见 .monoDigit()）。
    static let num = dyn(light: rgb(0x1e2528), dark: rgb(0xe8ecee))

    // MARK: 语义结果色（ok/warn/err，Chip/StatusMark/横幅用）

    static let ok = dyn(light: rgb(0x15803d), dark: rgb(0x5fd577))
    static let warn = dyn(light: rgb(0x92400e), dark: rgb(0xffb340))
    static let err = dyn(light: rgb(0xb91c1c), dark: rgb(0xff8d86))
    /// 星级金（TASK-142：本地模型卡质量星级，bench 原型 --star）。
    static let star = dyn(light: rgb(0xe8a33d), dark: rgb(0xf0b25e))
    /// 删除确认遮罩（TASK-143：bench 原型 --mask，非毛玻璃平色）。
    static let maskScrim = dyn(light: rgba(0x0a1014, 0.22), dark: rgba(0x000000, 0.42))

    // MARK: 结构色（边线/填充/控件底）

    /// 玻璃面板亮边描边（0.5px hairline）。
    static let border = dyn(light: .white.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.12))
    /// 分隔细线 line。
    static let line = dyn(light: rgba(0x1e2528, 0.14), dark: .white.withAlphaComponent(0.10))
    /// 强分隔线 line2。
    static let line2 = dyn(light: rgba(0x1e2528, 0.22), dark: .white.withAlphaComponent(0.16))
    /// 输入框底 field。
    static let field = dyn(light: .white.withAlphaComponent(0.55), dark: .white.withAlphaComponent(0.07))
    /// 软填充（正文卡底）fillSoft。
    static let fillSoft = dyn(light: rgba(0x1e2528, 0.05), dark: .white.withAlphaComponent(0.05))
    /// 中性实色 fill（波形/滑块等）。
    static let fill = dyn(light: rgb(0x8e9396), dark: rgb(0xa6abad))
    /// 失败平直波形条 barFlat。
    static let barFlat = dyn(light: rgba(0x1e2528, 0.25), dark: .white.withAlphaComponent(0.3))
    /// 分段控件底 segBg。
    static let segBg = dyn(light: rgba(0x1e2528, 0.07), dark: .white.withAlphaComponent(0.06))
    /// 分段选中底 segOn。
    static let segOn = dyn(light: .white.withAlphaComponent(0.92), dark: .white.withAlphaComponent(0.14))
    /// 侧栏底 sideBg。
    static let sideBg = dyn(light: .white.withAlphaComponent(0.3), dark: .white.withAlphaComponent(0.04))
    /// 侧栏选中项底 navOn。
    static let navOn = dyn(light: .white.withAlphaComponent(0.55), dark: .white.withAlphaComponent(0.08))
    /// 列表行选中底 rowSelected（glassStyles.rowSelected）。
    static let rowSelected = dyn(light: rgba(0x1e2528, 0.06), dark: .white.withAlphaComponent(0.07))
    /// 拨杆关态 togOff。
    static let togOff = dyn(light: rgba(0x787d80, 0.4), dark: rgb(0x3a3a42))
    /// 胶囊面板底 capsBg（叠毛玻璃材质，屏 A）。
    static let capsBg = dyn(light: .white.withAlphaComponent(0.72), dark: rgba(0x262c30, 0.72))
    /// 模态遮罩 overlay。
    static let overlay = dyn(light: rgba(0xeef3f5, 0.62), dark: rgba(0x0a0c0e, 0.62))
    /// 模态卡底 modalBg。
    static let modalBg = dyn(light: rgba(0xfafcfd, 0.95), dark: rgb(0x2c3438))

    // MARK: 主按钮反转色（glassStyles.btnPrimary：浅主题深底白字 / 深主题浅底深字）

    static let primaryBg = dyn(light: rgb(0x2b3338), dark: rgb(0xe8ecee))
    static let primaryFg = dyn(light: rgb(0xf2f6f7), dark: rgb(0x1e2528))
    /// 灰实心按钮（2026-10-12 追裁「灰色不是黑色」：真灰非炭黑——本地卡下载/使用、
    /// 两页供应商卡「使用」图标钮（TASK-146 起图标语言共用 RailButton）；
    /// 保存等全站主按钮仍用 primaryBg 不动）。
    static let grayBtnBg = dyn(light: rgb(0x5c666a), dark: rgb(0xa8b1b5))
    static let grayBtnFg = dyn(light: rgb(0xffffff), dark: rgb(0x1e2528))

    // MARK: 色调底/边（Chip 与横幅按语义叠加品牌色低透明度，SPEC §4 小面积原则）

    /// 品牌蓝 10% 底 + 45% 边（类型徽标·风格 / 选中态）。
    static let blueTintBg = dyn(light: rgba(0x029cfa, 0.1), dark: rgba(0x029cfa, 0.1))
    static let blueTintBorder = dyn(light: rgba(0x029cfa, 0.45), dark: rgba(0x029cfa, 0.45))
    /// 卡片激活态淡蓝（2026-10-11 追裁调浅加透明；TASK-146 起本地模型卡与两页
    /// 供应商卡三处激活态统一此值——独立取值，勿与引擎状态条/选中态亮蓝的
    /// blueTint 混用）。
    static let softBlueTintBg = dyn(light: rgba(0x029cfa, 0.06), dark: rgba(0x029cfa, 0.075))
    static let softBlueTintBorder = dyn(light: rgba(0x029cfa, 0.32), dark: rgba(0x029cfa, 0.32))
    static let greenTintBg = dyn(light: rgba(0x30d158, 0.16), dark: rgba(0x30d158, 0.12))
    static let greenTintBorder = dyn(light: rgba(0x30d158, 0.35), dark: rgba(0x30d158, 0.35))
    static let redTintBg = dyn(light: rgba(0xff453a, 0.12), dark: rgba(0xff453a, 0.14))
    static let redTintBorder = dyn(light: rgba(0xff453a, 0.42), dark: rgba(0xff453a, 0.35))
    static let orangeTintBg = dyn(light: rgba(0xff9f0a, 0.16), dark: rgba(0xff9f0a, 0.12))
    static let orangeTintBorder = dyn(light: rgba(0xff9f0a, 0.38), dark: rgba(0xff9f0a, 0.38))
    /// 失败横幅底/边（详情页）。
    static let failBannerBg = dyn(light: rgba(0xff453a, 0.09), dark: rgba(0xff453a, 0.09))
    static let failBannerBorder = dyn(light: rgba(0xff453a, 0.32), dark: rgba(0xff453a, 0.32))

    // MARK: 字体（数字用 SF Mono + tabular-nums，SPEC §1 排印规范）

    /// 等宽数字修饰：SF Mono + tabular-nums（计时/延迟/计数/字数）。
    static func mono(_ size: CGFloat = 12.5) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    // MARK: 布局常量（§20 排印终值单点化，§85 收敛——此前字面量散布各页）

    /// 设置卡行值列宽度（TASK-082 追裁 330→230：值列右移、标签↔控件间距加大）。
    static let valueColumnWidth: CGFloat = 230

    // MARK: 外观三段接线（跟随系统/浅色/深色，驱动全部动态色与系统材质）

    /// 把 AppSettings.Appearance 应用到 NSApp（nil = 跟随系统）。
    /// 启动时调用一次 + 观察 UserDefaults 变化重调（设置页写入即生效，无需重启）。
    static func applyAppearance(_ appearance: AppSettings.Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 窗口毛玻璃背景（NSVisualEffectView 近似 v2-glass blur+saturate）

/// 背景毛玻璃：behindWindow 混合，随 NSApp.appearance 自动切浅/深。
