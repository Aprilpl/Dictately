import SwiftUI
import UniformTypeIdentifiers

/// 左栏工作台（方案 D 单卡流 + 多文件队列增补）：
/// empty（拖放）/ picked（文件列表+模型节）/ running（队列+进度）/ done（批次结果）
/// + hist（右栏点入的历史条目视图，底部 srcnote）。
struct TranscribeWorkbenchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importerShown = false
    @State private var dropTargeted = false

    private var controller: FileTranscribeController { environment.fileTranscribe }

    /// fileImporter 白名单（mp3/wav/m4a；取不到系统类型时回退 .audio 由 addFileURLs 再过滤）。
    private static let importerTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ["mp3", "wav", "m4a"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types.isEmpty ? [.audio] : types
    }()

    var body: some View {
        VStack(spacing: 14) {
            if let entryID = controller.viewingEntryID {
                historyEntrySection(entryID)
            } else {
                switch controller.phase {
                case .empty: dropCard
                case .picked: pickedCard
                case .running: runningCard
                case .done: doneSection
                }
            }
        }
        .fileImporter(
            isPresented: $importerShown,
            allowedContentTypes: Self.importerTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                controller.addFileURLs(urls)
            }
        }
    }

    // MARK: - empty（拖放区）

    private var dropCard: some View {
        SettingsCard {
            dropZone
                .padding(10)
                .frame(maxHeight: .infinity) // 空态等高裁决：接受右栏高度提案撑满（内容居中）
        }
        .frame(maxHeight: .infinity)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(dropTargeted ? Theme.softBlueTintBg : .clear)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(dropTargeted ? Theme.blue : Theme.text3)
                Text("transcribe.drop.title")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                HStack(spacing: 6) {
                    ForEach(["mp3", "wav", "m4a"], id: \.self) { ext in
                        Text(ext)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Theme.field))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(.vertical, 46)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    dropTargeted ? Theme.blue : Theme.line,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(Rectangle())
        .onTapGesture { importerShown = true }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { controller.addFileURLs([url]) }
                }
            }
            return true
        }
    }

    // MARK: - picked（文件列表 + 模型节 + 开始）

    private var pickedCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 13) {
                ForEach(controller.pendingFiles) { file in
                    pendingFileRow(file)
                }
                DashedDivider()
                    .padding(.vertical, 2)
                TranscribeSectionLabel(key: "transcribe.section.model")
                TranscribeModelPicker(controller: controller)
                if !controller.selectionValid {
                    Text(selectionHint)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                }
                actionRow
            }
            .padding(.vertical, 16)
        }
    }

    /// picked 文件行（图标 + 名称 + `ext · 时长 · 大小` meta + 移除钮）。
    private func pendingFileRow(_ file: PendingTranscribeFile) -> some View {
        HStack(spacing: 10) {
            TranscribeFileIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine(ext: file.ext, durationMs: file.durationMs, sizeBytes: file.sizeBytes))
                    .font(Theme.mono(10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            Button {
                controller.removeFile(file.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.field))
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(String(localized: "transcribe.file.remove"))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                importerShown = true
            } label: {
                Label(String(localized: "transcribe.add.more"), systemImage: "plus")
            }
            .buttonStyle(.themeGhost)
            Spacer()
            Button {
                controller.startTranscription()
            } label: {
                Label(startLabel, systemImage: "play.fill")
            }
            .buttonStyle(.themePrimary)
            .disabled(!controller.canStart)
        }
    }

    private var startLabel: String {
        controller.pendingFiles.count > 1
            ? String(format: String(localized: "transcribe.start.count"), controller.pendingFiles.count)
            : String(localized: "transcribe.start")
    }

    /// 选择无效时的门槛提示（未配 Key / 模型未下载）。
    private var selectionHint: String {
        controller.selection.mode == .local
            ? String(localized: "transcribe.hint.modelMissing")
            : String(localized: "transcribe.hint.keyMissing")
    }

    // MARK: - running（队列 + 当前行进度 + 取消）

    private var runningCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 13) {
                // 批次头：总进度 + 已用
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(batchHeaderText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    TranscribeElapsedText(style: .running)
                }
                // 模型行（整批同模型；原型 pnote2）
                modelInfoLine
                ForEach(controller.queueItems) { item in
                    queueRow(item)
                }
                HStack {
                    Spacer()
                    Button {
                        controller.cancelAll()
                    } label: {
                        Label(String(localized: "transcribe.cancel"), systemImage: "xmark")
                    }
                    .buttonStyle(.themeGhost)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private var batchHeaderText: String {
        let done = controller.queueItems.filter { $0.state == .succeeded || $0.state == .failed }.count
        return String(format: String(localized: "transcribe.progress.head"), done, controller.queueItems.count)
    }

    /// 模型信息行：彩点 + 名称 + 说明（本地=音频不出设备 / API=云端转写）。
    private var modelInfoLine: some View {
        let isLocal = controller.selection.mode == .local
        let name = isLocal
            ? (controller.selection.localRepoID.flatMap { LocalModelCatalog.model(id: $0)?.name } ?? "")
            : controller.selection.apiProvider.displayName
        return HStack(spacing: 7) {
            Circle().fill(isLocal ? Theme.blue : Theme.ok).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
            Text("·").foregroundStyle(Theme.text3)
            Text(isLocal
                ? String(localized: "transcribe.model.localNote")
                : String(localized: "transcribe.model.apiNote"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
    }

    /// 队列行：状态图标 + 文件名；当前转写行展开进度条与预估。
    private func queueRow(_ item: TranscribeQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stateIcon(item)
                Text(item.fileName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                stateText(item)
            }
            if item.state == .running {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HStack(spacing: 8) {
                            Text("\(Int((item.progress * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.blue)
                            if let index = item.sliceIndex, let count = item.sliceCount {
                                Text(String(format: String(localized: "transcribe.progress.slice"), index, count))
                                    .font(.system(size: 10.5))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.text3)
                            }
                        }
                        Spacer()
                        QueueEtaText(item: item)
                    }
                    TranscribeProgressBar(progress: item.progress)
                }
                .padding(.leading, 26)
            }
            if item.state == .failed, let message = item.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.err)
                    .lineLimit(2)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateIcon(_ item: TranscribeQueueItem) -> some View {
        switch item.state {
        case .waiting:
            Circle().fill(Theme.line).frame(width: 7, height: 7)
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ok)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.err)
        }
    }

    @ViewBuilder
    private func stateText(_ item: TranscribeQueueItem) -> some View {
        switch item.state {
        case .waiting:
            Text("transcribe.state.waiting")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        case .running:
            Text("transcribe.state.running")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.blue)
        case .succeeded:
            Text("transcribe.state.done")
                .font(.system(size: 10.5)).foregroundStyle(Theme.ok)
        case .failed:
            Text("transcribe.state.failed")
                .font(.system(size: 10.5)).foregroundStyle(Theme.err)
        }
    }

    // MARK: - done（批次头 + 每文件结果/错误卡 + 转写下一个）

    private var doneSection: some View {
        VStack(spacing: 14) {
            SettingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doneHeaderText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        TranscribeElapsedText(style: .done)
                    }
                    Spacer()
                    IconButton(icon: "plus") {
                        controller.resetToEmpty()
                    }
                    .help(String(localized: "transcribe.next"))
                }
                .padding(.vertical, 14)
            }
            ForEach(controller.batchResults) { entry in
                if entry.status == .succeeded {
                    TranscribeResultCard(entry: entry)
                } else {
                    TranscribeErrorCard(entry: entry)
                }
            }
        }
    }

    private var doneHeaderText: String {
        let ok = controller.batchResults.filter { $0.status == .succeeded }.count
        let failed = controller.batchResults.count - ok
        if failed > 0 {
            return String(format: String(localized: "transcribe.done.mixed"), ok, failed)
        }
        return String(format: String(localized: "transcribe.done.all"), ok)
    }

    // MARK: - hist（历史条目视图 + srcnote）

    private func historyEntrySection(_ entryID: Int64) -> some View {
        // hist 提示文字（transcribe.hist.note）2026-10-26 用户裁决退役
        Group {
            if controller.retryingEntryID == entryID {
                retryProgressCard(entryID)
            } else if let entry = controller.viewingDetail {
                if entry.status == .succeeded {
                    TranscribeResultCard(entry: entry)
                } else {
                    TranscribeErrorCard(entry: entry)
                }
            } else {
                SettingsCard {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                            .frame(height: 80)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
            }
        }
    }

    /// 历史重试进度卡（原型 h._run：文件行 + 进度条；2026-10-25 用户补裁：
    /// 重试进行中加「取消」——与批次运行卡同款右下角 ghost 取消钮）。
    private func retryProgressCard(_ entryID: Int64) -> some View {
        SettingsCard {
            let entry = controller.viewingDetail
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TranscribeFileIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry?.fileName ?? "—")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("transcribe.retry.running")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.blue)
                    }
                    Spacer()
                    Text("\(Int((controller.retryProgress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.blue)
                }
                TranscribeProgressBar(progress: controller.retryProgress)
                HStack {
                    Spacer()
                    Button {
                        controller.cancelRetry()
                    } label: {
                        Label(String(localized: "transcribe.cancel"), systemImage: "xmark")
                    }
                    .buttonStyle(.themeGhost)
                }
            }
            .padding(.vertical, 15)
        }
    }

    // MARK: - 共用

    private func metaLine(ext: String, durationMs: Int?, sizeBytes: Int64) -> String {
        let duration = durationMs.map { TranscribeFormat.duration($0 / 1000) } ?? "—"
        return "\(ext) · \(duration) · \(TranscribeFormat.size(sizeBytes))"
    }
}

// MARK: - 结果卡（done 单文件 / hist 详情共用）

/// 转写成功结果卡：文件头 + 引擎 chip + 文本框（内滚）+ AI 总结/复制 + 摘要卡。
struct TranscribeResultCard: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: FileTranscript
    /// hist 详情 = true（时间列显示相对时间；done = false 显示用时）。
    var isHistory = false

    private var controller: FileTranscribeController { environment.fileTranscribe }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                headRow
                textBox
                actionRow
                if let summary = entry.summary {
                    summaryCard(summary)
                }
            }
            .padding(.vertical, 15)
        }
    }

    private var headRow: some View {
        HStack(spacing: 10) {
            TranscribeFileIcon(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: String(localized: "transcribe.result.done"), timeText))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 4)
            TranscribeEngineChip(mode: entry.mode, modelName: entry.modelName)
        }
    }

    private var timeText: String {
        if isHistory {
            return RelativeTime.string(from: Date(timeIntervalSince1970: entry.createdAt))
        }
        return TranscribeFormat.duration((entry.transcribeMs ?? 0) / 1000)
    }

    /// 转写文本框（浅底圆角、pre-wrap、maxHeight 内滚——原型 .trans 同形态）。
    private var textBox: some View {
        ScrollView(.vertical) {
            Text(entry.text ?? "")
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundStyle(Theme.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 280)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 0.5))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            TranscribeSummarizeControl(
                entryID: entry.id ?? -1, hasSummary: entry.summary != nil)
            IconButton(icon: "doc.on.doc") {
                environment.clipboard.write(entry.text ?? "")
                environment.toast.show(String(localized: "transcribe.toast.copied"))
            }
            .help(String(localized: "transcribe.copy.help"))
            Spacer()
        }
    }

    /// AI 总结三态：未总结（蓝 sparkle 图标钮）/ 正在总结…（spinner 文字 chip）/ 已总结（文字 chip）。
    /// 文字钮 → 图标钮简化（TASK-157）；状态 chip 保留文字（状态非操作）。
    /// 读取叶子化（TASK-158）：summarizingIDs 的观察收进本控件——任一卡总结状态
    /// 变化不再波及所有结果卡整卡重算。

    /// 摘要卡（蓝 tint 底：标题 + 来源注 + Markdown 正文（内滚）+ 图标钮操作行）。
    /// TASK-156：正文由逐行蓝点列表改为 Markdown 结构化渲染；TASK-157：底部操作行
    /// 图标化（重新生成 + 复制摘要），重新生成期间旧内容置灰保留、两钮禁用。
    /// TASK-158：正文+操作行收进 SummaryBodyPane 叶子（置灰态观察隔离）。
    private func summaryCard(_ raw: String) -> some View {
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.blue)
                Text("transcribe.summary.title")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                Text(summarySourceText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                if controller.summaryUsesCustomPrompt {
                    summaryCustomChip
                }
            }
            SummaryBodyPane(entryID: entry.id ?? -1, raw: raw)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.blueTintBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.blueTintBorder, lineWidth: 0.5))
    }

    /// 「已自定义」chip（TASK-155：总结预设 = 自定义时挂来源注右侧）。
    private var summaryCustomChip: some View {
        Text("transcribe.summary.custom")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.blueTintBg))
            .overlay(Capsule().strokeBorder(Theme.blueTintBorder, lineWidth: 0.5))
    }

    /// 摘要来源注（TASK-156 精简）：「模型ID · 提示词名称」——跟随全局与钉选统一
    /// 显生效模型 ID（原「由 服务 · 模型 生成 · 预设」长句退役，2026-10-25 用户裁决）。
    private var summarySourceText: String {
        let resolution = FileTranscribeController.resolvedSummaryLLM(settings: environment.settings)
        return String(
            format: String(localized: "transcribe.summary.source"),
            resolution.model,
            environment.settings.transcribeSummaryPreset.displayName)
    }
}

// MARK: - 错误卡（done 失败行 / hist 失败详情共用）

/// 转写失败错误卡：原因行 + 保留提示 + 「重新转写」。
struct TranscribeErrorCard: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: FileTranscript

    private var controller: FileTranscribeController { environment.fileTranscribe }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.err)
                    Text(String(format: String(localized: "transcribe.error.title"), entry.errorMessage ?? "—", entry.modelName))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(2)
                }
                Text("transcribe.error.hint")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                HStack {
                    IconButton(icon: "arrow.clockwise", variant: .danger) {
                        if let id = entry.id {
                            controller.retryEntry(id)
                        }
                    }
                    .help(String(localized: "transcribe.retry"))
                    Spacer()
                }
            }
            .padding(.vertical, 15)
        }
    }
}

// MARK: - 观察粒度叶子视图（TASK-158：高频状态变化的读取收进最小子视图，
// ticker 每秒/总结状态变化不再驱动整页与全部结果卡 body 重算）

/// 批次已用秒文本（running 头右缘 / done 头副行；读取旁路的 batchElapsedSeconds）。
private struct TranscribeElapsedText: View {
    enum Style {
        /// 「已用 x:xx」（running 卡头）。
        case running
        /// 「用时 x:xx」（done 卡头）。
        case done
    }

    @Environment(AppEnvironment.self) private var environment
    let style: Style

    var body: some View {
        let seconds = environment.fileTranscribe.batchElapsedSeconds
        return Text(String(
            format: String(localized: style == .running ? "transcribe.progress.elapsed" : "transcribe.done.elapsed"),
            TranscribeFormat.duration(Int(seconds))))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Theme.text3)
    }
}

/// 队列行 ETA 文本（预估来自 item.estimateSeconds、已用秒来自旁路字典——
/// 每 1s 只有本视图失效）。
private struct QueueEtaText: View {
    @Environment(AppEnvironment.self) private var environment
    let item: TranscribeQueueItem

    var body: some View {
        let elapsed = environment.fileTranscribe.itemElapsedSeconds[item.id] ?? 0
        let remain = item.estimateSeconds - elapsed
        return Text(remain >= 1
            ? String(format: String(localized: "transcribe.progress.eta"), TranscribeFormat.duration(Int(remain)))
            : String(localized: "transcribe.progress.etaUnknown"))
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(Theme.text3)
    }
}

/// AI 总结三态控件（未总结蓝图标钮 / 正在总结… / 已总结 chip；见 actionRow 注）。
private struct TranscribeSummarizeControl: View {
    @Environment(AppEnvironment.self) private var environment
    let entryID: Int64
    let hasSummary: Bool

    private var controller: FileTranscribeController { environment.fileTranscribe }

    var body: some View {
        if controller.summarizingIDs.contains(entryID) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("transcribe.summary.running")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if hasSummary {
            Label(String(localized: "transcribe.summary.done"), systemImage: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.field))
        } else {
            IconButton(icon: "sparkle", variant: .blue) {
                controller.summarize(entryID)
            }
            .disabled(!controller.llmConfigured)
            .help(String(localized: "transcribe.summary.help"))
        }
    }
}

/// 摘要卡正文 + 操作行（重新生成置灰/禁用态观察隔离在此叶子）。
private struct SummaryBodyPane: View {
    @Environment(AppEnvironment.self) private var environment
    let entryID: Int64
    let raw: String

    private var controller: FileTranscribeController { environment.fileTranscribe }

    var body: some View {
        let isRegenerating = controller.summarizingIDs.contains(entryID)
        return VStack(alignment: .leading, spacing: 9) {
            ScrollView(.vertical) {
                SummaryMarkdownView(raw: raw)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 470)
            .opacity(isRegenerating ? 0.45 : 1)
            .disabled(isRegenerating)
            HStack(spacing: 8) {
                Spacer()
                IconButton(icon: "arrow.clockwise") {
                    controller.summarize(entryID, isRegeneration: true)
                }
                .disabled(isRegenerating)
                .help(String(localized: "transcribe.summary.regen.help"))
                IconButton(icon: "doc.on.doc") {
                    environment.clipboard.write(raw)
                    environment.toast.show(String(localized: "transcribe.toast.copied"))
                }
                .disabled(isRegenerating)
                .help(String(localized: "transcribe.summary.copy"))
            }
        }
    }
}
