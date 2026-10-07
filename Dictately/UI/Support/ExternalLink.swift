import SwiftUI
import AppKit

/// 官网外链文字链（TASK-108）：品牌蓝 12pt + 小号 ↗ 符号，悬停下划线，
/// 点击 NSWorkspace.open 打开默认浏览器（AboutView 先例）。
/// 站内首例文字超链接形态——此前外开一律 ghost 按钮（关于页/数据文件夹）；
/// AI 服务与听写模型二级页的「获取 API Key」共用本组件。
struct ExternalLink: View {
    let title: LocalizedStringKey
    let url: URL

    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.blue)
            .underline(hovering, color: Theme.blue)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
