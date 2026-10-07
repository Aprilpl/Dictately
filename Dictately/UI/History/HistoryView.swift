import SwiftUI

/// 历史列表页（PRD FR-011 / §8 屏 B）：筛选 tab + 搜索（防抖 300ms）+ 排序下拉 +
/// 仅看失败开关 + 分页列表（50/页 触底加载）+ 点击进详情（右栏）。
/// 2026-10-01 用户裁决新增删除能力：行内悬停「复制」后跟「删除」（确认后删行+音频）；
/// 筛选栏「多选」进入选择模式（点行勾选/全选/删除所选，批量删除同样确认）。
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all, dictation, style
        var id: String { rawValue }

        var queryType: Entry.Kind? {
            switch self {
            case .all: return nil
            case .dictation: return .dictation
            case .style: return .style
            }
        }

        var labelKey: LocalizedStringKey {
            switch self {
            case .all: return "history.filter.all"
            case .dictation: return "history.filter.dictation"
            case .style: return "history.filter.style"
            }
        }

        /// 分段控件用（GlassSegmented 需要纯 String）。
        var title: String {
            switch self {
            case .all: return String(localized: "history.filter.all")
            case .dictation: return String(localized: "history.filter.dictation")
            case .style: return String(localized: "history.filter.style")
            }
        }
    }

    /// 状态筛选（TASK-097，2026-10-03 用户裁决：可筛成功也可筛失败，替换「仅看失败」开关）。
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, ok, failed
        var id: String { rawValue }

        var queryStatus: EntryQuery.Status? {
            switch self {
            case .all: return nil
            case .ok: return .ok
            case .failed: return .failed
            }
        }

        var title: String {
            switch self {
            case .all: return String(localized: "history.status.all")
            case .ok: return String(localized: "history.status.ok")
            case .failed: return String(localized: "history.status.failed")
            }
        }
    }

    @State private var entries: [Entry] = []
    @State private var total = 0
    @State private var styleNames: [Int64: String] = [:]
    @State private var filter: TypeFilter = .all
    @State private var statusFilter: StatusFilter = .all
    @State private var ascending = false
    @State private var searchText = ""
    @State private var debouncedKeyword = ""
    @State private var selectedEntryID: Int64?
    @State private var isLoadingMore = false
    @State private var loadFailedMessage: String?
    @State private var searchDebounce: Task<Void, Never>?
    /// 多选模式（2026-10-01 用户裁决）：true 时点行 = 勾选，不进详情。
    @State private var multiSelectActive = false
    /// 已勾选条目 id（仅多选模式有效；全选作用于当前已加载页）。
    @State private var selectedIDs: Set<Int64> = []
    /// 行内删除确认目标（nil = 无待确认删除）。
    @State private var pendingDelete: Entry?
    /// 批量删除确认。
    @State private var confirmMultiDelete = false

    private let pageSize = 50

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterBar
                Rectangle().fill(Theme.line).frame(height: 0.5)
                if let selected {
                    // §8 屏 C：「在右栏或替换列表显示」——取右栏形态
                    EntryDetailView(
                        entry: selected,
                        onClose: { selectedEntryID = nil },
                        onChanged: { reload() })
                } else {
                    entryList
                }
            }
            // TASK-084 终值（四轮）：居中限宽列上限 1040（940 时两侧 ≈151pt，
            // 用户调小为 ≈100pt：1242.5−1040−64 = 138.5 → 每侧 69.25+32 ≈ 101pt）。
            // 窄窗自动收窄不溢出（固定大 padding 在默认 960 窗会挤爆筛选条，弃用）。
            .frame(maxWidth: 1040)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            reload()
            applyDebugSelectArgument()
            applyDebugToastArgument()
        }
        .onChange(of: filter) { _, _ in reload() }
        .onChange(of: statusFilter) { _, _ in reload() }
        .onChange(of: ascending) { _, _ in reload() }
        .onChange(of: debouncedKeyword) { _, _ in reload() }
        .confirmationDialog(
            "detail.delete.confirm",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("detail.delete.confirm.ok", role: .destructive) {
                if let entry = pendingDelete { deleteSingle(entry) }
                pendingDelete = nil
            }
            Button("detail.delete.confirm.cancel", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(
            String(format: String(localized: "history.delete.selected.confirm"), selectedIDs.count),
            isPresented: $confirmMultiDelete,
            titleVisibility: .visible
        ) {
            Button("detail.delete.confirm.ok", role: .destructive) { deleteSelected() }
            Button("detail.delete.confirm.cancel", role: .cancel) {}
        }
    }

    // MARK: - 筛选区（tab + 搜索 + 排序 + 仅看失败；TASK-038 v2-glass 转录）

    private var filterBar: some View {
        HStack(spacing: 10) {
            GlassSegmented(
                options: TypeFilter.allCases,
                selection: $filter,
                small: true,
                label: { $0.title }
            )

            TextField("history.search.placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(maxWidth: 280)
                .background(FieldBackground())
                .onChange(of: searchText) { _, newValue in
                    // FR-011：防抖 300ms
                    searchDebounce?.cancel()
                    searchDebounce = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !Task.isCancelled {
                            debouncedKeyword = newValue.trimmingCharacters(in: .whitespaces)
                        }
                    }
                }

            sortMenu

            statusMenu

            multiSelectButton

            Spacer()
        }
        // TASK-084 终值（二轮）：左右留白由页级居中限宽列承担（见 body 三明治），筛选条贴列缘；
        // 顶部 36（TASK-082 ×3）/ 底部 12 维持。
        .padding(.top, 36)
        .padding(.bottom, 12)
    }

    /// 多选开关（激活态主按钮、普通态 ghost；进入/退出都清选择与详情）。
    @ViewBuilder
    private var multiSelectButton: some View {
        let toggle = {
            multiSelectActive.toggle()
            if !multiSelectActive { selectedIDs.removeAll() }
            selectedEntryID = nil
        }
        if multiSelectActive {
            Button("history.select", action: toggle)
                .buttonStyle(.themePrimary)
                .controlSize(.small)
                .disabled(entries.isEmpty)
        } else {
            Button("history.select", action: toggle)
                .buttonStyle(.themeGhost)
                .controlSize(.small)
                .disabled(entries.isEmpty)
        }
    }

    /// 排序下拉（v2-glass Dropdown 形态：field 底 + ▾）。
    private var sortMenu: some View {
        Menu {
            Button("history.sort.newest") { ascending = false }
            Button("history.sort.oldest") { ascending = true }
        } label: {
            HStack(spacing: 8) {
                Text(ascending ? "history.sort.oldest" : "history.sort.newest")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 状态筛选下拉（TASK-097 用户裁决：全部状态/仅成功/仅失败，替换「仅看失败」开关；
    /// 选「仅失败」时 label 转 warn——原型语义）。sortMenu 同款形态。
    private var statusMenu: some View {
        Menu {
            Button("history.status.all") { statusFilter = .all }
            Button("history.status.ok") { statusFilter = .ok }
            Button("history.status.failed") { statusFilter = .failed }
        } label: {
            HStack(spacing: 8) {
                Text(statusFilter.title)
                    .font(.system(size: 13))
                    .foregroundStyle(statusFilter == .failed ? Theme.warn : Theme.text1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(FieldBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 列表

    private var entryList: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // TASK-096：hairline 行 → 卡片列表（卡片间距 12，行底分隔线退役）
                    LazyVStack(spacing: 12) {
                        ForEach(entries, id: \.id) { entry in
                            EntryRow(
                                entry: entry,
                                isSelected: entry.id == selectedEntryID,
                                isSelectMode: multiSelectActive,
                                isChecked: selectedIDs.contains(entry.id ?? -1),
                                onSelect: {
                                    // 多选模式：点行 = 勾选；普通模式：进详情
                                    if multiSelectActive {
                                        toggleSelection(entry)
                                    } else {
                                        selectedEntryID = entry.id
                                    }
                                },
                                onCopy: { copy(entry) },
                                onDelete: { pendingDelete = entry },
                                styleNameByID: styleNames)
                                .onAppear {
                                    loadMoreIfNeeded(current: entry)
                                }
                        }
                        if isLoadingMore {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("history.loadingMore")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.text3)
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let loadFailedMessage {
                Text(loadFailedMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.err)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
            } else if multiSelectActive {
                multiSelectBar
            }
        }
    }

    /// 多选操作栏（底部浮动）：全选（当前已加载页）/ 已选计数 / 删除所选 / 完成。
    private var multiSelectBar: some View {
        let allLoadedSelected = !entries.isEmpty
            && entries.allSatisfy { selectedIDs.contains($0.id ?? -1) }
        return HStack(spacing: 10) {
            Button(allLoadedSelected ? "history.unselectAll" : "history.selectAll") {
                if allLoadedSelected {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(entries.compactMap(\.id))
                }
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)

            Text(String(format: String(localized: "history.selectedCount"), selectedIDs.count))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)

            Spacer()

            Button("history.delete.selected") { confirmMultiDelete = true }
                .buttonStyle(.themeDanger)
                .controlSize(.small)
                .disabled(selectedIDs.isEmpty)

            Button("history.select.done") {
                multiSelectActive = false
                selectedIDs.removeAll()
            }
            .buttonStyle(.themeGhost)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        // TASK-084 终值（二轮）：外距由页级居中限宽列承担，卡片贴列缘（卡内内容距不变）
        .padding(.bottom, 12)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    /// 空状态（PRD US-006 逐字；搜索无结果同款；v2-glass：静止低条 + t2 文案）。
    private var emptyState: some View {
        VStack(spacing: 14) {
            WaveformView(isActive: false, sample: { nil }, barHeight: 20)
            Text("history.empty")
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private var selected: Entry? {
        entries.first { $0.id == selectedEntryID }
    }

    private func currentQuery(offset: Int = 0) -> EntryQuery {
        EntryQuery(
            type: filter.queryType,
            status: statusFilter.queryStatus,
            keyword: debouncedKeyword.isEmpty ? nil : debouncedKeyword,
            ascending: ascending,
            limit: pageSize,
            offset: offset
        )
    }

    private func reload() {
        // TASK-098：不再清 selectedEntryID——「重新生成」完成后详情原地刷新（selected
        // 按 id 在新 entries 里重查，条目仍在则显示新 finalText；被筛掉/删除则详情自然消失）
        loadFailedMessage = nil
        do {
            entries = try environment.entryRepository.fetchPage(currentQuery())
            total = try environment.entryRepository.count(matching: currentQuery())
            if let allStyles = try? environment.styleRepository.fetchAll() {
                styleNames = Dictionary(
                    uniqueKeysWithValues: allStyles.compactMap { style in
                        style.id.map { ($0, style.name) }
                    })
            }
        } catch {
            loadFailedMessage = String(describing: error)
            entries = []
        }
    }

    /// 触底加载下一页（FR-011：分页 50/页）。
    private func loadMoreIfNeeded(current: Entry) {
        guard current.id == entries.last?.id,
              entries.count < total,
              !isLoadingMore else { return }
        isLoadingMore = true
        let next = try? environment.entryRepository.fetchPage(currentQuery(offset: entries.count))
        if let next, !next.isEmpty {
            entries.append(contentsOf: next.filter { new in
                !entries.contains(where: { $0.id == new.id })
            })
        }
        isLoadingMore = false
    }

    private func copy(_ entry: Entry) {
        if let text = entry.finalText ?? entry.rawText {
            environment.clipboard.write(text)
            environment.toast.show(String(localized: "history.toast.copied"))
        }
    }

    // MARK: - 删除（2026-10-01 用户裁决；FR-012 语义：DB 行 + 音频文件同时清理）

    private func toggleSelection(_ entry: Entry) {
        guard let id = entry.id else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSingle(_ entry: Entry) {
        guard let id = entry.id else { return }
        do {
            if let audioPath = try environment.entryRepository.delete(id: id) {
                environment.audioStore.delete(path: audioPath)
            }
            selectedIDs.remove(id)
            reload()
        } catch {
            loadFailedMessage = String(describing: error)
        }
    }

    /// 批量删除所选（逐条走 repo.delete；失败即停并把错误浮出，已删部分生效）。
    private func deleteSelected() {
        do {
            for id in selectedIDs {
                if let audioPath = try environment.entryRepository.delete(id: id) {
                    environment.audioStore.delete(path: audioPath)
                }
            }
            selectedIDs.removeAll()
            multiSelectActive = false
            reload()
        } catch {
            loadFailedMessage = String(describing: error)
        }
    }

    /// Debug 自动化：`--toast-demo` 启动 0.8s 后弹一枚「已复制」Toast（TASK-097 截图
    /// 瞬态用——Toast 1.6s 自动消失，人工走查也可直接点任意复制按钮）。
    private func applyDebugToastArgument() {
        #if DEBUG
        guard CommandLine.arguments.contains("--toast-demo") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            environment.toast.show(String(localized: "history.toast.copied"))
        }
        #endif
    }

    /// Debug 自动化：`--history-detail` 直进首条详情（TASK-096 截图/走查用）；
    /// `--history-select` 进入多选模式并预选前两条（截图/走查用，
    /// 与 RootView `--page` 同款机制；仅 Debug 编译进二进制）。
    private func applyDebugSelectArgument() {
        #if DEBUG
        guard !entries.isEmpty else { return }
        if CommandLine.arguments.contains("--history-failed") {
            statusFilter = .failed   // TASK-097 截图用：直达「仅失败」筛选态（label warn）
        }
        if CommandLine.arguments.contains("--history-detail") {
            selectedEntryID = entries.first?.id
            return
        }
        guard CommandLine.arguments.contains("--history-select") else { return }
        multiSelectActive = true
        selectedIDs = Set(entries.prefix(2).compactMap(\.id))
        #endif
    }
}

// MARK: - 列表行（TASK-096 卡片化重设计，2026-10-03 用户裁决）
// 供应商卡同语言：圆角 12 / fillSoft 底 + line 边 / 内距 15·12 / 卡距 12 / hover line2 /
// 选中蓝调（blueTint，替换旧 rowSelected + 左缘蓝条）；标题主导两行 = 摘要 14 semibold
// 单行截断 + 元信息行（m:ss 时长 + 风格 chip + 诊断 chip）；「已粘贴」chip 不展示。

struct EntryRow: View {
    let entry: Entry
    let isSelected: Bool
    /// 多选模式：true 时左侧显勾选圈、悬停动作隐藏、点行回调 = 勾选。
    var isSelectMode = false
    var isChecked = false
    let onSelect: () -> Void
    let onCopy: () -> Void
    /// 行内删除（悬停「删除」按钮；确认弹窗在父级）。
    var onDelete: (() -> Void)?
    /// styleId → 风格名（列表页注入，行内展示「风格名 · ⌘N」chip）。
    var styleNameByID: [Int64: String] = [:]

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if isSelectMode {
                checkIndicator
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TypeBadge(isStyle: entry.type == .style)
                    Text(summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 8) {
                    Text(duration)
                        .font(Theme.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                    if let styleChip {
                        Chip(text: styleChip, tone: .neutral)
                    }
                    statusChip
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text(RelativeTime.string(from: Date(timeIntervalSince1970: entry.createdAt)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                HStack(spacing: 6) {
                    if hovering && !isSelectMode {
                        Button("history.copy", action: onCopy)
                            .buttonStyle(.themeGhost)
                            .controlSize(.small)
                        if let onDelete {
                            Button("history.delete", action: onDelete)
                                .buttonStyle(.themeDanger)
                                .controlSize(.small)
                        }
                    }
                    if !isSelectMode {
                        StatusMark(isOK: entry.status != .failed)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected || (isSelectMode && isChecked) ? Theme.blueTintBg : Theme.fillSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected || (isSelectMode && isChecked) ? Theme.blueTintBorder
                        : (hovering ? Theme.line2 : Theme.line),
                    lineWidth: 1))
        .animation(.easeInOut(duration: 0.18), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }

    /// 勾选圈（多选模式左侧；选中 = 品牌蓝底白勾）。
    private var checkIndicator: some View {
        ZStack {
            Circle()
                .fill(isChecked ? Theme.blue : .clear)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().strokeBorder(isChecked ? Theme.blue : Theme.line, lineWidth: 1.5))
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var summary: String {
        if entry.status == .failed {
            let reason = entry.errorMessage ?? entry.errorKind ?? ""
            return String(format: String(localized: "history.failedSummary"), reason)
        }
        return entry.finalText ?? entry.rawText ?? "—"
    }

    /// 「风格名 · ⌘N」chip（style 条目且能查到风格名）。
    private var styleChip: String? {
        guard entry.type == .style, let styleID = entry.styleId,
              let name = styleNameByID[styleID] else { return nil }
        return name
    }

    /// 诊断 chip（2026-10-03 裁决：「已粘贴」不展示——成功+已粘贴为最常见态，不再显 chip；
    /// 仅保留罕见诊断态：已复制(中性)/已回退粘贴原文(橙)/音频已保留(橙)）。
    @ViewBuilder
    private var statusChip: some View {
        switch (entry.status, entry.pasted) {
        case (.success, true):
            EmptyView()
        case (.success, false):
            Chip(text: String(localized: "history.copiedOnly"), tone: .neutral)
        case (.failed, true):
            Chip(text: String(localized: "history.fallbackPasted"), tone: .orange)
        default:
            Chip(text: String(localized: "history.audioKept"), tone: .orange)
        }
    }

    /// 时长 m:ss（TASK-096：与录音 HUD 计时同格式，复用 PanelFormat.recordingClock）。
    private var duration: String {
        guard let ms = entry.audioDurationMs else { return "—" }
        return PanelFormat.recordingClock(ms: ms)
    }
}
