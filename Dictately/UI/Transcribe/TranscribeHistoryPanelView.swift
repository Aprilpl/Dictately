import SwiftUI

/// 右栏常驻「转写历史」面板（方案 D historyPanel）：条目行（状态点 + 文件名 +
/// 模型·时间 + 失败 chip + 行内删除），点击载入左栏详情并高亮。
struct TranscribeHistoryPanelView: View {
    @Environment(AppEnvironment.self) private var environment

    private var controller: FileTranscribeController { environment.fileTranscribe }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("transcribe.panel.title")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                Text(String(format: String(localized: "transcribe.panel.count"), controller.history.count))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
            .padding(.bottom, 10)

            if controller.history.isEmpty {
                Text("transcribe.panel.empty")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    // 空态等高（TASK-165）：撑满剩余高度让文案垂直居中，与左卡拖放区居中形态呼应
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 26)
            } else {
                ScrollView(.vertical) {
                    // LazyVStack（TASK-158，沿 HistoryView 惯例）：视口外行不构造
                    // ——此前 300 行全量建（520pt 视口外也建行 + 相对时间串）。
                    LazyVStack(spacing: 2) {
                        ForEach(controller.history) { entry in
                            row(entry)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 520)
            }
        }
        // 内侧高度弹性（TASK-165，§76 追裁二机制修正）：空态等高分支的提案要能
        // 传进 background 内侧，可见卡片才撑得满——弹性 frame 加在调用处（background
        // 外侧）只会得到一个隐形高框居中矮卡。nil 提案（其余态/堆叠态）仍报理想高，
        // 右栏自然高不变。
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fillSoft))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func row(_ entry: FileTranscriptListItem) -> some View {
        let active = controller.viewingEntryID == entry.id
        return Button {
            controller.selectHistoryEntry(entry.id)
        } label: {
            HStack(spacing: 8) {
                statusDot(entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileName)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(entry.modelName) · \(RelativeTime.string(from: Date(timeIntervalSince1970: entry.createdAt)))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.status == .failed {
                    Text("transcribe.panel.failed")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.err)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.redTintBg))
                }
                Button {
                    controller.deleteEntry(entry.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "transcribe.panel.delete"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(active ? Theme.navOn : .clear))
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.blue)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusDot(_ entry: FileTranscriptListItem) -> some View {
        switch entry.status {
        case .succeeded:
            Circle().fill(Theme.ok).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Theme.err).frame(width: 7, height: 7)
        case .running:
            ProgressView().controlSize(.mini)
        }
    }
}
