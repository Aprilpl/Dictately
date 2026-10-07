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

    // MARK: 色调底/边（Chip 与横幅按语义叠加品牌色低透明度，SPEC §4 小面积原则）

    /// 品牌蓝 10% 底 + 45% 边（类型徽标·风格 / 选中态）。
    static let blueTintBg = dyn(light: rgba(0x029cfa, 0.1), dark: rgba(0x029cfa, 0.1))
    static let blueTintBorder = dyn(light: rgba(0x029cfa, 0.45), dark: rgba(0x029cfa, 0.45))
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
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - 通用组件（v2-glass 原子：Chip / TypeBadge / StatusMark / Kbd / SettingRow / Segmented）

/// 语义色调小徽标（glassStyles.chip + Chip tones）。
struct Chip: View {
    enum Tone { case neutral, blue, green, red, orange }

    let text: String
    var tone: Tone = .neutral
    /// 覆盖字体（mono 模型名 chip 等场景）；nil = 默认 12pt medium。
    var font: Font?

    var body: some View {
        Text(text)
            .font(font ?? .system(size: 12, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 1))
    }

    private var fg: Color {
        switch tone {
        case .neutral, .blue: Theme.text2
        case .green: Theme.ok
        case .red: Theme.err
        case .orange: Theme.warn
        }
    }

    private var bg: Color {
        switch tone {
        case .neutral: Theme.fillSoft
        case .blue: Theme.blueTintBg
        case .green: Theme.greenTintBg
        case .red: Theme.redTintBg
        case .orange: Theme.orangeTintBg
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: Theme.line
        case .blue: Theme.blueTintBorder
        case .green: Theme.greenTintBorder
        case .red: Theme.redTintBorder
        case .orange: Theme.orangeTintBorder
        }
    }
}

/// 类型徽标：风格 = 品牌蓝调；听写 = 中性（TypeBadge）。
struct TypeBadge: View {
    let isStyle: Bool

    var body: some View {
        Chip(text: isStyle ? "风格" : "听写", tone: isStyle ? .blue : .neutral)
    }
}

/// 状态标：成功 ✓（ok 绿）/ 失败 ⚠（warn 橙）（StatusMark，符号制不用 emoji）。
struct StatusMark: View {
    let isOK: Bool

    var body: some View {
        Text(isOK ? "✓" : "⚠")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isOK ? Theme.ok : Theme.warn)
            .frame(width: 16)
    }
}

/// kbd 键帽（本方向签名细节）：SF Mono + 发丝边 + 微立体。
struct KbdKey: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(Theme.mono(size))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize() // 键帽原子性：空间不足时整体不被压缩（bug00010 残留：Esc 被挤成竖排两行）
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.dyn(light: .white.withAlphaComponent(0.55), dark: .white.withAlphaComponent(0.08))))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Theme.dyn(light: .white.withAlphaComponent(0.75), dark: .white.withAlphaComponent(0.16)),
                        lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
    }
}

/// 设置行：label + hint 左，控件右，底部分隔线（SettingRow）。
struct SettingRow<Content: View>: View {
    let label: LocalizedStringKey
    /// 动态标题（风格名等用户数据）：按字面显示，不做本地化键查找
    /// （LocalizedStringKey 会按键查表，用户数据必须原样呈现；裁决 #12）。
    var plainTitle: String?
    var plainHint: String?
    var hint: LocalizedStringKey?
    /// false = 不画底部分隔线（SettingsCard 分组卡的末行，避免与卡边框贴成双线）。
    var divider: Bool
    @ViewBuilder var content: () -> Content

    init(
        _ label: LocalizedStringKey, hint: LocalizedStringKey? = nil, divider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.plainTitle = nil
        self.plainHint = nil
        self.hint = hint
        self.divider = divider
        self.content = content
    }

    /// 动态文案行（风格名等非 LocalizedStringKey 标题；快捷键页风格组合行用，裁决 #12）。
    /// 参数名 title: 与 LocalizedStringKey 版区分调用歧义。
    init(
        title: String, hint: String? = nil, divider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = ""
        self.plainTitle = title
        self.plainHint = hint
        self.hint = nil
        self.divider = divider
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if let plainTitle {
                    Text(plainTitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text1)
                } else {
                    Text(label)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text1)
                }
                if let plainHint {
                    Text(plainHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                } else if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if divider { Divider().overlay(Theme.line) } }
    }
}

/// 纵排设置行（v2-glass SettingRow `stack` 形态）：label/hint 在上，宽内容在下
/// （语言提示 chips、热词表格、Base URL 宽输入等）。
/// 撑满可用宽度：内容窄（如 330pt 输入框）时分隔线也只随内容宽——2026-10-01
/// 用户截图实锤的半截线 bug，容器级补 frame 修正。
struct SettingStackRow<Content: View>: View {
    let label: LocalizedStringKey
    var hint: LocalizedStringKey?
    /// false = 不画底部分隔线（SettingsCard 分组卡的末行）。
    var divider: Bool
    @ViewBuilder var content: () -> Content

    init(
        _ label: LocalizedStringKey, hint: LocalizedStringKey? = nil, divider: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.divider = divider
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text1)
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if divider { Divider().overlay(Theme.line) } }
    }
}

/// 设置分组卡（设置页表单容器，与供应商卡/提示横幅同一表面语言）：
/// fillSoft 底 + line 边 + 12 圆角；横向 padding 15 由容器统一给，
/// 行自带的底部分隔线随之内缩对齐文字（末行传 divider: false）。
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// 毛玻璃风格分段选择器（Segmented：segBg 底 + segOn 选中浮层）。
struct GlassSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var small = false
    /// 选项文案（String 原始值直接用；枚举传本地化闭包）。
    var label: (Option) -> String = { option in
        Mirror(reflecting: option).descendant("rawValue") as? String
            ?? (option as? String)
            ?? String(describing: option)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text1 : Theme.text2)
                        .padding(.horizontal, small ? 9 : 12)
                        .padding(.vertical, small ? 3 : 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.segOn : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.segBg))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

// MARK: - 拨杆开关（v2-glass Toggle：胶囊轨道 + 白圆钮，0.18s 滑动）

/// 毛玻璃拨杆开关。开态品牌蓝（2026-10-01 用户裁决，原型原为状态绿）、
/// 关态 togOff、白圆钮带微阴影；38×22（small 34×20）。
///
/// 持本地态驱动重绘：上层 Binding 多为 AppSettings 直写（非 Observable），
/// 点击后不会触发本视图重绘——拨钮必须自己记住状态；
/// `onChange` 回灌外部变化（如登录启动 onAppear 系统状态同步）。
struct GlassToggle: View {
    @Binding var isOn: Bool
    @State private var local: Bool
    var small = false
    var disabled = false

    init(isOn: Binding<Bool>, small: Bool = false, disabled: Bool = false) {
        _isOn = isOn
        _local = State(initialValue: isOn.wrappedValue)
        self.small = small
        self.disabled = disabled
    }

    private var width: CGFloat { small ? 34 : 38 }
    private var height: CGFloat { small ? 20 : 22 }

    var body: some View {
        Button {
            local.toggle()
            isOn = local
        } label: {
            ZStack(alignment: local ? .trailing : .leading) {
                Capsule().fill(local ? Theme.blue : Theme.togOff)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onChange(of: isOn) { _, newValue in
            local = newValue
        }
        .animation(.easeInOut(duration: 0.18), value: local)
    }
}

// MARK: - 按钮样式（Btn：primary 反转 / ghost 玻璃 / danger 红调）

/// 主按钮：浅主题深底白字 / 深主题浅底深字（glassStyles.btnPrimary）。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.primaryFg)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.primaryBg))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 幽灵按钮：玻璃底 + 亮边（glassStyles.btnGhost）。
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.dyn(light: .white.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.08))))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 危险按钮：红调底 + err 前景（glassStyles.btnDanger）。
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.err)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.redTintBg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.redTintBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var themePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var themeGhost: GhostButtonStyle { GhostButtonStyle() }
}

extension ButtonStyle where Self == DangerButtonStyle {
    static var themeDanger: DangerButtonStyle { DangerButtonStyle() }
}

// MARK: - 文本输入底（input：field 底 + line2 边）

/// 文本框/下拉统一玻璃底（设置页表单用；叠在系统控件后面近似 ray-input）。
struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line2, lineWidth: 0.5))
    }
}

/// 编辑态输入框（2026-10-01 用户裁决的统一交互，自温度控件推广全站设置值输入）：
/// - 未聚焦 = 无边框纯文本（当前值/灰 placeholder），不呈输入框；
/// - 点击聚焦 = 玻璃底输入框 + 品牌蓝 focus ring；
/// - 回车（onSubmit）/ 鼠标移开（onHover）/ 焦点转移 = 退出编辑恢复纯文本
///   （点击窗口空白 macOS 不转移焦点，必须显式退出路径）；
/// - `invalid` = 值非法提示（红边，聚焦与否均显示——与蓝框互斥优先蓝框）。
struct GlassField: View {
    var placeholder: LocalizedStringKey
    @Binding var text: String
    /// 密钥类输入（SecureField 圆点显示）。
    var isSecure = false
    var width: CGFloat? = nil
    /// mono 字体（URL/Key/模型名/数值类输入）。
    var monospaced = true
    /// 文字对齐（默认 leading；数值短框可用 trailing 贴值列右缘，与相邻下拉值同列）。
    var textAlignment: TextAlignment = .leading
    var invalid = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        isSecure: Bool = false,
        width: CGFloat? = nil,
        monospaced: Bool = true,
        textAlignment: TextAlignment = .leading,
        invalid: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.width = width
        self.monospaced = monospaced
        self.textAlignment = textAlignment
        self.invalid = invalid
        self.onSubmit = onSubmit
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(monospaced ? Theme.mono(12.5) : .system(size: 13))
            .multilineTextAlignment(textAlignment)
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(Group { if focused { FieldBackground() } else { Color.clear } })
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1))
            .focused($focused)
            .onSubmit {
                focused = false
                onSubmit?()
            }
            .onHover { hovering in
                if !hovering { focused = false }
            }
            .animation(.easeInOut(duration: 0.15), value: focused)
    }

    @ViewBuilder private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var borderColor: Color {
        if focused { return Theme.blueTintBorder }
        return invalid ? Theme.redTintBorder : .clear
    }
}

// MARK: - 统一提示横幅（TASK-043：一行原因 + 可选动作按钮，全 App 错误/警示同构）

/// 语义横幅：warn（橙）/ error（红）/ success（绿）三种色调，图标 + 主行 + 可选副行 +
/// 可选动作按钮。PRD §11 各错误场景的 UI 呈现统一走这里（面板胶囊内除外）。
struct NoticeBanner: View {
    enum Tone { case warn, error, success }

    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    var tone: Tone = .warn

    /// 动态文案便捷入口（错误消息已是用户可读文本，不做键查找）。
    init(
        title message: String,
        subtitle: String? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        tone: Tone = .warn
    ) {
        self.title = LocalizedStringKey(message)
        self.subtitle = subtitle.map { LocalizedStringKey($0) }
        self.actionTitle = actionTitle
        self.action = action
        self.tone = tone
    }

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil,
        tone: Tone = .warn
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(accent)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.themeGhost)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(border, lineWidth: 1))
    }

    private var icon: String {
        switch tone {
        case .warn, .error: return "⚠"
        case .success: return "✓"
        }
    }

    private var accent: Color {
        switch tone {
        case .warn: return Theme.warn
        case .error: return Theme.err
        case .success: return Theme.ok
        }
    }

    private var bg: Color {
        switch tone {
        case .warn: return Theme.orangeTintBg
        case .error: return Theme.failBannerBg
        case .success: return Theme.greenTintBg
        }
    }

    private var border: Color {
        switch tone {
        case .warn: return Theme.orangeTintBorder
        case .error: return Theme.failBannerBorder
        case .success: return Theme.greenTintBorder
        }
    }
}
