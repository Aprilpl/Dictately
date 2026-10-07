import SwiftUI

/// 条目详情（PRD FR-012 / §8 屏 C）：元数据行 + raw/final 对照（style）或单栏
/// （dictation）+ 失败信息突出（含副行引导）。
/// TASK-097 追裁（同日）：操作按钮自底栏上移顶栏（返回之后，底栏整体退役）、
/// 动作反馈走全站 Toast（environment.toast）。
/// TASK-100（2026-10-03 追裁）：听写 = 「复制 + 重新转写」（对已存音频重跑 ASR，
/// .copyOnly 既有链路——更新条目不粘贴；音频缺失禁用）。TASK-096：操作按钮按类型分化——听写原仅「复制」；
/// 风格 = 「复制听写内容 / 复制润色内容 / 重新生成」（重新生成 = 对听写文字重跑
/// LLM 润色后原地渲染）；「重试 / 重试并复制 / 删除」从详情页退役——删除路径 =
/// 列表行悬停 + 多选批量，失败条目不再有重跑转写（ASR）入口（用户知情裁决）。
struct EntryDetailView: View {
    let entry: Entry
    let onClose: () -> Void
    /// 重新生成完成后列表/详情刷新回调。
    let onChanged: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var isRetrying = false

    /// 音频是否仍在（TASK-100：「重新转写」禁用判定——音频被清理/缺失即不可重跑）。
    private var audioURL: URL? {
        guard let path = entry.audioPath,
              let url = environment.audioStore.resolve(path: path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entry.status == .failed {
                        failureBanner
                    }
                    metadata
                    textSections
                }
                // TASK-084 用户终值（二轮）：详情内容区水平 100（与顶/底栏对齐）；
                // TASK-096：垂直 20 → 24（间距放大裁决）
                .padding(.horizontal, 100)
                .padding(.vertical, 24)
            }
            // TASK-097：底栏退役——操作按钮上移顶栏（见 header），ScrollView 占满余高。
        }
    }

    // MARK: - 头部（返回列表 + 类型徽标）

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onClose()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                    Text("detail.back")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
            }
            .buttonStyle(.plain)

            // 操作按钮组（TASK-097 追裁：自底栏上移顶栏、跟随返回之后）
            HStack(spacing: 8) {
                if entry.type == .style {
                    Button("detail.copyRaw") { copyRaw() }
                        .buttonStyle(.themeGhost)
                    Button("detail.copyFinal") { copyFinal() }
                        .buttonStyle(.themeGhost)
                    Button("detail.regen") { regen() }
                        .buttonStyle(.themeGhost)
                        .disabled(isRetrying || (entry.rawText ?? "").isEmpty)
                } else {
                    Button("history.copy") { copyFinal() }
                        .buttonStyle(.themeGhost)
                    Button("detail.retranscribe") { retranscribe() }
                        .buttonStyle(.themeGhost)
                        .disabled(isRetrying || audioURL == nil)
                }
                if isRetrying {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.leading, 20)

            Spacer()
            TypeBadge(isStyle: entry.type == .style)
        }
        .padding(.horizontal, 100) // TASK-084 用户终值（二轮）：详情内边 60→100（顶/底栏三处对齐）
        .padding(.vertical, 12)
    }

    /// 失败信息突出显示（NoticeBanner：一行原因 + 副行引导，error 色调）。
    private var failureBanner: some View {
        NoticeBanner(
            title: entry.errorMessage ?? entry.errorKind ?? "",
            subtitle: failureSubTitle,
            tone: .error
        )
    }

    /// 失败副文案：风格条目引导「重新生成」；听写仅陈述状态（无重试入口，裁决后语义）。
    private var failureSubTitle: String {
        if entry.type == .style {
            return entry.pasted
                ? String(localized: "detail.failsub.style.fallback")
                : String(localized: "detail.failsub.style.kept")
        }
        return entry.pasted
            ? String(localized: "detail.failsub.plain.fallback")
            : String(localized: "detail.failsub.plain.kept")
    }

    // MARK: - 元数据（TASK-099 追裁二：三行制——①时间+时长 ②听写模型+ASR 耗时
    // ③AI提示模型+LLM 耗时；听写条目仅前两行，失败条目 LLM 未完成无第三行——
    // llmModel 只在润色成功后落库，此前从未展示）

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(RelativeTime.fullString(from: Date(timeIntervalSince1970: entry.createdAt)))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text2)
                if entry.audioDurationMs != nil {
                    dot
                    durationText
                }
            }
            if entry.asrModel != nil || entry.asrLatencyMs != nil {
                HStack(spacing: 8) {
                    if let model = entry.asrModel {
                        modelGroup("detail.model.asr", model)
                    }
                    if let asr = entry.asrLatencyMs {
                        if entry.asrModel != nil { dot }
                        Text("ASR \(String(format: "%.1f", Double(asr) / 1000))s")
                            .font(Theme.mono(13))
                            .monospacedDigit()
                            .foregroundStyle(Theme.num)
                    }
                }
            }
            if let llmModel = entry.llmModel, entry.status != .failed {
                HStack(spacing: 8) {
                    modelGroup("detail.model.llm", llmModel)
                    if let llm = entry.llmLatencyMs {
                        dot
                        Text("LLM \(String(format: "%.1f", Double(llm) / 1000))s")
                            .font(Theme.mono(13))
                            .monospacedDigit()
                            .foregroundStyle(Theme.num)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private var durationText: some View {
        let ms = entry.audioDurationMs ?? 0
        return Text(String(format: String(localized: "detail.duration"), PanelFormat.recordingClock(ms: ms)))
            .font(Theme.mono(13))
            .monospacedDigit()
            .foregroundStyle(Theme.num)
    }

    /// 模型成组：小标签（听写/AI提示，12.5 t3）+ mono 模型名（13 t1）。
    private func modelGroup(_ label: LocalizedStringKey, _ model: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
            Text(model)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text1)
        }
    }

    private var dot: some View {
        Text("·").font(.system(size: 13.5)).foregroundStyle(Theme.text3)
    }

    // MARK: - 正文（style：左右对照；dictation：单栏；TASK-096：栏标题 13.5 seclabel
    // 规格、正文 15pt、文本卡内距 18·16 圆角 12）

    @ViewBuilder
    private var textSections: some View {
        if entry.type == .style {
            HStack(alignment: .top, spacing: 16) {
                textColumn(title: "detail.rawTitle", text: entry.rawText, prominent: false)
                textColumn(title: "detail.finalTitle", text: entry.finalText ?? entry.rawText, prominent: true)
            }
        } else {
            textColumn(title: "detail.finalTitle", text: entry.finalText ?? entry.rawText, prominent: true)
        }
    }

    private func textColumn(title: LocalizedStringKey, text: String?, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text3)
            Text(text ?? "—")
                .font(.system(size: 15))
                .lineSpacing(8)
                .foregroundStyle(prominent ? Theme.text1 : Theme.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    // MARK: - 动作

    private func copyRaw() {
        if let text = entry.rawText {
            environment.clipboard.write(text)
            environment.toast.show(String(localized: "history.toast.copiedRaw"))
        }
    }

    private func copyFinal() {
        if let text = entry.finalText ?? entry.rawText {
            environment.clipboard.write(text)
            environment.toast.show(String(localized: "history.toast.copiedFinal"))
        }
    }

    /// 重新转写（TASK-100 追裁）：对已存音频重跑 ASR（.copyOnly 既有链路——更新条目
    /// **不粘贴**：从历史页向前台 App 粘贴语义意外，老「重试」(.full) 的粘贴行为不复活）
    /// → 落库 → 列表与详情原地刷新；音频缺失时按钮已禁用。
    private func retranscribe() {
        guard !isRetrying else { return }
        isRetrying = true
        environment.toast.show(String(localized: "history.toast.retranscribe"), info: true)
        let entryID = entry.id ?? -1
        environment.pipeline.retryEntry(id: entryID, mode: .copyOnly) { [weak environment] in
            isRetrying = false
            var latest: Entry?
            if let environment { latest = try? environment.entryRepository.fetch(id: entryID) }
            if latest?.status == .success {
                environment?.toast.show(String(localized: "detail.retranscribe.done"))
            } else {
                environment?.toast.show(String(localized: "history.toast.retranscribeFailed"), info: true)
            }
            onChanged()
        }
    }

    /// 重新生成（2026-10-03 裁决）：对听写文字重跑 LLM 润色（polishOnly 既有链路）
    /// → 落库 → 列表与详情原地刷新；进度与完成反馈走 Toast（TASK-097）。
    private func regen() {
        guard !isRetrying else { return }
        isRetrying = true
        environment.toast.show(String(localized: "history.toast.regen"), info: true)
        let entryID = entry.id ?? -1
        environment.pipeline.retryEntry(id: entryID, mode: .polishOnly) { [weak environment] in
            isRetrying = false
            // 完成真伪按落库最新状态判定（TASK-098：门禁短路/LLM 失败都不得弹成功文案）
            var latest: Entry?
            if let environment { latest = try? environment.entryRepository.fetch(id: entryID) }
            if latest?.status == .success {
                environment?.toast.show(String(localized: "detail.regen.done"))
            } else {
                environment?.toast.show(String(localized: "history.toast.regenFailed"), info: true)
            }
            onChanged()
        }
    }
}
