import SwiftUI

/// 风格列表页（PRD FR-010 / §8 屏 E）：每个风格一张卡（2026-10-01 bug00009 裁决：
/// 卡片形式替代 hairline 行，与 AI 服务页分组卡同一表面语言）——
/// 开关 + 名称/内置徽标 + 描述副行 + ⌘ + N 键帽 + ›；点击进编辑；
/// 新建与编辑进入 StyleEditorView；内置不可删（无删除入口），
/// 自定义删除弹确认（SPEC 逐字：「删除后历史记录保留，条目显示为已删除风格。」）。
/// 内容列限宽 620（bug00011 同款防漂移：宽窗下控件不贴窗缘）。
struct StyleListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var styles: [Style] = []
    @State private var editingStyle: Style?
    @State private var creatingNew = false
    @State private var pendingDelete: Style?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let editing = editingStyle {
                StyleEditorView(
                    style: editing,
                    onSave: { changed in save(changed) },
                    onCancel: { editingStyle = nil },
                    onDelete: { pendingDelete = editing }
                )
            } else if creatingNew {
                StyleEditorView(
                    style: nil,
                    onSave: { changed in save(changed) },
                    onCancel: { creatingNew = false }
                )
            } else {
                list
            }
        }
        .onAppear {
            reload()
            applyDebugEditorArgument()
        }
        .confirmationDialog(
            "styles.delete.confirm",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("styles.delete.confirm.ok", role: .destructive) {
                if let style = pendingDelete { delete(style) }
                pendingDelete = nil
                editingStyle = nil
            }
            Button("styles.delete.confirm.cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            // 头部（v2-glass StylePane：标题 + t3 提示 + 右侧主按钮）；与卡片同列限宽。
            // 提示动态列出已绑定组合（裁决 #12：组合可自定义，不再写死 ⌘ + 1 / ⌘ + 2）。
            HStack(spacing: 10) {
                Text("styles.title")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text(hintString)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button("styles.new") {
                    creatingNew = true
                    errorMessage = nil
                }
                .buttonStyle(.themePrimary)
                .controlSize(.small)
            }
            // TASK-077 用户裁决：内容列弹性 + 居中（同常规设置页）；TASK-080 追裁上限 800。
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            // TASK-082：顶部间距 14→42（×3），底部维持 14
            .padding(.top, 42)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .center)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.err)
                    .frame(maxWidth: 800, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            ScrollView {
                // TASK-085 用户追裁：风格卡片间距 10→24（原紧凑列表密度调宽松）
                LazyVStack(spacing: 24) {
                    ForEach(styles, id: \.id) { style in
                        card(style)
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 风格卡（bug00009）：开关 + 名称/内置徽标 + 描述副行（替代旧标签 chip）+
    /// 快捷键组合键帽（裁决 #12：自定义组合；无效存储串按未绑定显示）+ ›；
    /// 卡面 fillSoft + line 边 + 12 圆角。
    private func card(_ style: Style) -> some View {
        HStack(spacing: 12) {
            GlassToggle(isOn: enabledBinding(style), small: true)

            Button {
                editingStyle = style
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(style.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        if style.isBuiltin {
                            Chip(text: String(localized: "styles.builtin.badge"), tone: .blue)
                        }
                    }
                    if let description = style.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let storage = style.hotkeyCombo, let combo = HotkeyCombo(storageString: storage) {
                KbdKey(text: combo.displayText)
            } else {
                Text("styles.unbound")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { editingStyle = style }
    }

    // MARK: - 数据

    /// 页头提示：动态列出启用风格的已绑定组合（至多三枚）；无绑定时通用引导文案。
    private var hintString: String {
        let displays = styles.filter(\.enabled).compactMap {
            $0.hotkeyCombo.flatMap(HotkeyCombo.init(storageString:))?.displayText
        }
        guard !displays.isEmpty else {
            return String(localized: "styles.hint.none", bundle: AppResources.bundle)
        }
        return String(
            format: String(localized: "styles.hint.combo", bundle: AppResources.bundle),
            displays.prefix(3).joined(separator: " / "))
    }

    /// Debug 自动化：`--style-editor` 直接进入首个风格的编辑页（截图/走查脚本用，
    /// 与 RootView `--page` 同款机制；仅 Debug 编译进二进制）。
    private func applyDebugEditorArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--style-editor"),
              let first = styles.first else { return }
        editingStyle = first
        #endif
    }

    private func reload() {
        do {
            styles = try environment.styleRepository.fetchAll()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func save(_ style: Style) {
        do {
            if style.id == nil {
                _ = try environment.styleRepository.insert(style)
            } else {
                _ = try environment.styleRepository.update(style) // hotkey 互斥在仓库层
            }
            editingStyle = nil
            creatingNew = false
            reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(_ style: Style) {
        do {
            try environment.styleRepository.delete(id: style.id!)
            reload() // 历史条目经 FK SET NULL 保留（TASK-025 用例锁定）
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func enabledBinding(_ style: Style) -> Binding<Bool> {
        Binding(
            get: { style.enabled },
            set: { isOn in
                var changed = style
                changed.enabled = isOn
                changed.updatedAt = Date().timeIntervalSince1970
                save(changed)
            })
    }
}
