import SwiftUI

/// 触发键「修改」菜单（TASK-153 · 方案 C 菜单直选 · 原型 hotkey-style-bind-c.html 定稿）：
/// 「录制新组合…」+ 分隔线 + 分组标题「使用风格快捷键」+ 风格行（右侧键帽、当前绑定 ✓）。
/// 点风格 = 绑定（按下该组合直接走该风格听写）；点「录制新组合…」进现行行内捕获。
/// 经 MenuPopoverHost 以 transient NSPopover 弹出于「修改」钮下缘。
struct TriggerKeyMenu: View {
    let model: TriggerKeyMenuModel
    let onRecordNew: () -> Void
    let onPickStyle: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TriggerMenuActionRow(
                leading: Text("settings.hotkey.trigger.menu.record")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text1),
                action: onRecordNew)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 0.5)
                .padding(.vertical, 5)

            Text("settings.hotkey.trigger.menu.section")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.bottom, 4)

            if model.items.isEmpty {
                Text("settings.hotkey.trigger.menu.empty")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 3)
            } else {
                ForEach(model.items, id: \.styleId) { item in
                    TriggerMenuStyleRow(
                        item: item,
                        isBound: item.styleId == model.boundStyleId,
                        onPick: { onPickStyle(item.styleId) })
                }
            }
        }
        .frame(width: 244)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.modalBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2, lineWidth: 1))
    }
}

/// 菜单纯函数模型（TASK-153）：eligible 过滤与绑定解析均无副作用，单测覆盖
/// （TriggerKeyMenuTests）。生效判定 `isBindable` 与 AppEnvironment.refreshTriggerStyleBinding
/// 同源（同文件单一谓词，两处共用——改一处即两处生效）。
struct TriggerKeyMenuModel: Equatable {
    struct Item: Equatable {
        let styleId: Int64
        let name: String
        let combo: HotkeyCombo
    }

    /// 可选风格：enabled 且已绑合法组合（与引擎 styleBindings 同口径——禁用/无键不列）。
    let items: [Item]
    /// 当前绑定风格 id（不在 items 内则无 ✓——不可解析态仍保留绑定存储）。
    let boundStyleId: Int64?

    /// 全量风格 → 菜单项（保留库排序）。无效组合存储串静默剔除（同引擎绑定集口径）。
    static func eligibleStyles(_ styles: [Style]) -> [Item] {
        styles.filter(\.enabled).compactMap { style in
            guard let id = style.id,
                  let storage = style.hotkeyCombo,
                  let combo = HotkeyCombo(storageString: storage) else { return nil }
            return Item(styleId: id, name: style.name, combo: combo)
        }
    }

    /// 绑定是否生效（存在 && enabled && 已绑组合）。nil/停用/失键 → false（自定义组合恢复）。
    static func isBindable(_ style: Style?) -> Bool {
        guard let style else { return false }
        return style.enabled && !(style.hotkeyCombo ?? "").isEmpty
    }

    /// 绑定 id → 风格解析（页面展示键帽/chip 用）。
    static func resolve(boundId: Int64?, styles: [Style]) -> Style? {
        guard let boundId else { return nil }
        let style = styles.first { $0.id == boundId }
        return isBindable(style) ? style : nil
    }
}

/// 通用菜单行（hover 换 fillSoft 底；独立小视图隔离 hover 态，ChannelRow 同款）。
private struct TriggerMenuActionRow<Leading: View>: View {
    let leading: Leading
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Theme.fillSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// 风格行：✓ 槽（当前绑定蓝勾，槽位常驻对齐）+ 名称 + 右缘等宽键帽。
private struct TriggerMenuStyleRow: View {
    let item: TriggerKeyMenuModel.Item
    let isBound: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Text("✓")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.blue)
                    .opacity(isBound ? 1 : 0)
                    .frame(width: 14)
                Text(item.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Spacer(minLength: 12)
                KbdKey(text: item.combo.displayText, size: 11)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Theme.fillSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
