import SwiftUI

/// 风格编辑器（PRD FR-010 / §8 屏 E）：名称（必填，空时行内「名称不能为空」）、
/// 描述、Prompt 大输入框（右下角 `216 / 8000` 字数）、快捷键录制控件
/// （裁决 #12：任意组合可录，选中被占组合提示「将解除『…』的组合绑定」）。
/// 启用不在编辑页出现（2026-10-01 bug00008 裁决：由列表页开关外部决定，
/// 保存时原值保留）。视觉（TASK-038，v2-glass 转录）：玻璃表单
/// （field 底输入、底部动作条 删除(danger，仅自定义)/取消(ghost)/保存(primary)）。
struct StyleEditorView: View {
    /// nil = 新建。
    let style: Style?
    let onSave: (Style) -> Void
    let onCancel: () -> Void
    /// 删除入口（自定义风格；由列表提供确认弹窗，SPEC：删除后历史保留）。
    var onDelete: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment

    @State private var name = ""
    @State private var description = ""
    @State private var prompt = ""
    @State private var promptFocused = false // TASK-086：Prompt 框聚焦态（蓝 ring）
    @State private var hotkeyComboStorage: String?
    @State private var attemptedSave = false
    @State private var conflictHint: String?

    static let promptLimit = 8000

    private var isBuiltin: Bool { style?.isBuiltin ?? false }

    var body: some View {
        ScrollView {
            // TASK-086：组间距 12→20（对齐列表页 24 卡间距的宽松节奏）
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onCancel) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.backward")
                        Text("styles.back")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)

                HStack(spacing: 9) {
                    Text(style == nil ? "styles.editor.newTitle" : "styles.editor.title")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text1)
                    if isBuiltin {
                        Chip(text: String(localized: "styles.builtin.badge"), tone: .blue)
                    }
                }

                fieldLabel("styles.editor.name")
                TextField("styles.editor.name.placeholder", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(FieldBackground())
                if attemptedSave && name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("styles.editor.name.empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.err)
                }

                fieldLabel("styles.editor.desc")
                TextField("styles.editor.desc.placeholder", text: $description)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(FieldBackground())

                fieldLabel("styles.editor.binding")
                HotkeyRecorder(
                    kind: .style,
                    current: hotkeyComboStorage.flatMap(HotkeyCombo.init(storageString:)),
                    onRecord: { combo in
                        hotkeyComboStorage = combo.storageString
                        updateConflictHint(combo)
                    },
                    onValidate: { combo in
                        combo == environment.settings.recordingHotkeyCombo
                            ? String(localized: "settings.hotkey.recorder.conflict.trigger", bundle: AppResources.bundle)
                            : nil
                    },
                    onUnbind: {
                        hotkeyComboStorage = nil
                        conflictHint = nil
                    }
                )
                if let hint = conflictHint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warn)
                }

                fieldLabel("styles.editor.prompt")
                promptField

                // 底部动作条（v2-glass：删除左，取消/保存右）
                HStack(spacing: 9) {
                    if !isBuiltin, let onDelete {
                        Button("styles.delete", action: onDelete)
                            .buttonStyle(.themeDanger)
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("styles.editor.cancel", action: onCancel)
                        .buttonStyle(.themeGhost)
                        .controlSize(.small)
                    Button("styles.editor.save") { save() }
                        .buttonStyle(.themePrimary)
                        .controlSize(.small)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 20)
            }
            // TASK-086 用户裁决：与 AI提示列表页同款三层居中限宽（800 列 + 22 内距 +
            // 宽窗居中；原 560 贴左）+ 顶部留白 42 对齐。
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 42)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
    }

    // MARK: - 组件

    /// TASK-086：对齐全站小节标签样式（13.5 semibold + tracking 1；去 -4 负间距 hack）。
    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 13.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
            .padding(.bottom, 8)
    }

    /// Prompt 大输入（TASK-086 重做）：PlainTextEditor（NSScrollView+NSTextView）固定高
    /// 300pt **内部可滚**——原 `TextField(axis:.vertical)+lineLimit(8...16)` 在 macOS
    /// 封顶 16 行不内滚、超长模板尾部不可见；FieldBackground 常显 + 聚焦蓝 ring
    /// （沿 DictationTestField 模式）+ 空态 placeholder 覆盖层 + 右下 `n / 8000` 计数
    /// （8000 上限硬截断保留）。
    private var promptField: some View {
        ZStack(alignment: .bottomTrailing) {
            PlainTextEditor(text: $prompt) { focused in
                promptFocused = focused
            }
            .frame(height: 300)
            .background(FieldBackground())
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(promptFocused ? Theme.blue : .clear, lineWidth: 1.5)
            )
            .onChange(of: prompt) { _, newValue in
                if newValue.count > Self.promptLimit {
                    prompt = String(newValue.prefix(Self.promptLimit)) // 8000 上限硬截断
                }
            }
            if prompt.isEmpty {
                Text("styles.editor.prompt.placeholder")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, PlainTextEditor.insetX + 2)
                    .padding(.vertical, PlainTextEditor.insetY + 1)
                    .allowsHitTesting(false)
            }
            Text("\(prompt.count) / \(Self.promptLimit)")
                .font(Theme.mono(12))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
    }

    /// 热键统一显示格式：HotkeyCombo.displayText（「⌘ + 1」带加号，bug00008/00009 裁决）。

    // MARK: - 数据

    private func load() {
        guard let style else { return }
        name = style.name
        description = style.description ?? ""
        prompt = style.prompt
        hotkeyComboStorage = style.hotkeyCombo
    }

    private func save() {
        attemptedSave = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return } // 行内校验已提示

        let now = Date().timeIntervalSince1970
        let changed = Style(
            id: style?.id,
            name: trimmedName,
            tags: style?.tags, // tags 列不在编辑器出现（UI 展示位由 description 承担）
            description: description.isEmpty ? nil : description,
            prompt: prompt,
            isBuiltin: style?.isBuiltin ?? false,
            hotkeyCombo: hotkeyComboStorage,
            enabled: style?.enabled ?? true, // 启用由列表页开关决定，编辑页不改动
            sortOrder: style?.sortOrder ?? 0,
            createdAt: style?.createdAt ?? now,
            updatedAt: now
        )
        onSave(changed)
    }

    /// 互斥提示：录制的组合当前绑在别的风格上 → 「将解除『…』的组合绑定」（FR-010）。
    private func updateConflictHint(_ combo: HotkeyCombo) {
        guard let holder = (try? environment.styleRepository.fetchByHotkey(combo.storageString)) ?? nil,
              holder.id != style?.id else {
            conflictHint = nil
            return
        }
        conflictHint = String(
            format: String(localized: "styles.editor.hotkey.conflict", bundle: AppResources.bundle),
            holder.name, combo.displayText)
    }
}
