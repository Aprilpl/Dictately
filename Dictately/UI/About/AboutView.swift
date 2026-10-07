import SwiftUI

/// 关于页（v2-glass `AboutPane` 逐项转录）：居中 App 图标 + 名称 + tagline +
/// 版本/系统 chips + 两行简介 + 检查更新/用户手册。
/// v1 无更新服务（PRD：Sparkle 后议）：检查更新打开仓库 Releases 页，用户手册打开 README。
struct AboutView: View {
    /// 开源发布链接（TASK-046 发布前改为实际仓库地址；当前占位指向 GitHub 组织检索）。
    private enum AppLinks {
        static let releases = URL(string: "https://github.com/Aprilpl/Dictately/releases")!
        static let manual = URL(string: "https://github.com/Aprilpl/Dictately#readme")!
    }

    var body: some View {
        // TASK-083 用户追裁：字体调大、间距调大（名称 18→21、tagline 13→15、
        // 简介 12.5→14、图标 56→64 随比例、各段间距同步放大、按钮升常规尺寸）。
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .shadow(color: .black.opacity(0.35), radius: 13, y: 8)

            Text("app.name")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.text1)
                .padding(.top, 20)
            Text("app.tagline")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text3)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Chip(text: versionText, tone: .neutral)
                Chip(text: "about.macos", tone: .neutral)
            }
            .padding(.top, 22)

            VStack(spacing: 4) {
                Text("about.desc.line1")
                Text("about.desc.line2")
            }
            .font(.system(size: 14))
            .multilineTextAlignment(.center)
            .lineSpacing(8)
            .foregroundStyle(Theme.text2)
            .padding(.top, 26)

            HStack(spacing: 9) {
                Button("about.checkUpdates") { NSWorkspace.shared.open(AppLinks.releases) }
                    .buttonStyle(.themeGhost)
                Button("about.manual") { NSWorkspace.shared.open(AppLinks.manual) }
                    .buttonStyle(.themeGhost)
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return String(format: String(localized: "about.version"), version, build)
    }
}
