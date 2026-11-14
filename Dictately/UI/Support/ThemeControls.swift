import SwiftUI
import AppKit

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

/// 分段文案字号（GlassSegmented 实际文案与等宽隐形捐赠者共用，泛型类型内
/// 不支持 static stored property 故置文件级）。
private let glassSegmentFontSize: CGFloat = 12.5

/// 毛玻璃风格分段选择器（Segmented：segBg 底 + segOn 选中浮层）。
/// 段标签整体 .contentShape(Rectangle())——整段药丸（含内距与透明底未选中态）
/// 皆可点，非仅文字命中（2026-10-12 用户实机反馈「只有点『API』两个字才切换」）。
struct GlassSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var small = false
    /// 等宽模式：各段取全部选项最宽文案的宽度（隐形捐赠者撑宽，文案居中）——
    /// 听写模型页 API/本地模型两框大小一致用（2026-10-12 用户裁决）；其余页
    /// 维持文字自适应宽度，勿擅自扩散（§19/§20 逐页裁决纪律）。
    var equalWidth = false
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
                    segmentText(option, selected: selected)
                        .padding(.horizontal, small ? 9 : 12)
                        .padding(.vertical, small ? 3 : 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.segOn : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 分段选中态必须暴露给读屏（TASK-178）；文案已由内部 Text 提供。
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.segBg))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 0.5))
    }

    /// 段文案：等宽模式以全部选项文案（统一 semibold 态——选中字重更宽，逐串
    /// semibold ≥ regular，取 max 即覆盖两态）为隐形捐赠者撑出统一文本宽，
    /// 实际文案（随选中态字重）居中其中——各段药丸同宽；非等宽模式仅实际文案。
    /// 隐形捐赠者走 SwiftUI 自身文本布局，无需 NSFont 量宽。
    private func segmentText(_ option: Option, selected: Bool) -> some View {
        ZStack {
            if equalWidth {
                ForEach(options, id: \.self) { donor in
                    Text(label(donor))
                        .font(.system(size: glassSegmentFontSize, weight: .semibold))
                        .hidden()
                }
            }
            Text(label(option))
                .font(.system(size: glassSegmentFontSize, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.text1 : Theme.text2)
        }
        .fixedSize(horizontal: true, vertical: false)
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
    /// 可访问性名称（必填，TASK-177）：自绘 Button 对 VoiceOver 只是「按钮」，
    /// 必须由调用点传入所在行的本地化标题，否则读屏无法判断在开关什么。
    let label: String
    @State private var local: Bool
    var small = false
    var disabled = false

    init(isOn: Binding<Bool>, label: String, small: Bool = false, disabled: Bool = false) {
        _isOn = isOn
        _local = State(initialValue: isOn.wrappedValue)
        self.label = label
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
        .accessibilityLabel(label)
        .accessibilityValue(local
            ? String(localized: "a11y.toggle.on")
            : String(localized: "a11y.toggle.off"))
        .onChange(of: isOn) { _, newValue in
            local = newValue
        }
        .animation(.easeInOut(duration: 0.18), value: local)
    }
}

// MARK: - 按钮样式（Btn：primary 反转 / blue 蓝底 / ghost 玻璃 / danger 红调）

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
