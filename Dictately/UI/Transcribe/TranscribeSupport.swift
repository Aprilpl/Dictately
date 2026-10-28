import SwiftUI

// MARK: - 格式化（视图层纯函数，§56 聚合/格式化分离纪律）

enum TranscribeFormat {
    /// 字节数 → "24.8 MB"（KB/MB/GB 自适应，一位小数）。
    static func size(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", gb)
    }

    /// 秒 → "m:ss" / "h:mm:ss"（原型 fmtDur 同口径）。
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - 共享小组件（页面私有；颜色全 Theme token）

/// 文件图标（音频波形，softBlueTint 圆角方块内品牌蓝图标）。
struct TranscribeFileIcon: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(Theme.softBlueTintBg)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(Theme.softBlueTintBorder, lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(Theme.blue)
            }
    }
}

/// 结果卡引擎 chip：本地 = 蓝底「… · 本地」；API = 绿底供应商名（原型 engineChip）。
struct TranscribeEngineChip: View {
    let mode: FileTranscript.Mode
    let modelName: String

    var body: some View {
        Text(chipText)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(isLocal ? Theme.blueTintBg : Theme.greenTintBg))
            .overlay(Capsule().strokeBorder(isLocal ? Theme.blueTintBorder : Theme.greenTintBorder, lineWidth: 0.5))
            .foregroundStyle(isLocal ? Theme.blue : Theme.ok)
    }

    private var isLocal: Bool { mode == .local }

    private var chipText: String {
        isLocal
            ? String(format: String(localized: "transcribe.chip.local"), modelName)
            : modelName
    }
}

/// 进度条（6pt 圆角，品牌蓝填充；原型 pbar 同形态，渐变改纯 token 蓝——硬约束 #3 禁硬编码色）。
struct TranscribeProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.field)
                Capsule()
                    .fill(Theme.blue)
                    .frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.25), value: progress)
    }
}

/// 小节标签（原型 .slab：12px / tracking 1 / text3）。
struct TranscribeSectionLabel: View {
    let key: LocalizedStringKey

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Theme.text3)
    }
}

/// 图标钮（TASK-157 · 原型 .ibtn）：操作行文字钮简化为纯图标——ghost = 28pt 描边圆
/// （原型：line2 描边 + t2 图标、hover t3/t1——浅色下必须清晰可辨，勿再降档）；
/// blue = 品牌蓝实心白图标（主操作）；danger = 语义红实心（对齐 themeDanger）；
/// wide = 44×28 r9 宽圆角（页头档）。`.disabled` 时 45% 降透明；含义靠 `.help` 承载。
struct IconButton: View {
    enum Variant { case ghost, blue, danger }

    let icon: String
    var variant: IconButton.Variant = .ghost
    var wide = false
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: wide ? 9 : 14)
    }

    private var isFilled: Bool { variant != .ghost }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isFilled ? Color.white : (hovering ? Theme.text1 : Theme.text2))
                .frame(width: wide ? 44 : 28, height: 28)
                .background {
                    if isFilled {
                        shape.fill(variant == .blue ? Theme.blue : Theme.err)
                    } else {
                        Circle().fill(hovering ? Theme.fillSoft : .clear)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        variant == .ghost ? (hovering ? Theme.text3 : Theme.line2) : .clear,
                        lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
    }
}
