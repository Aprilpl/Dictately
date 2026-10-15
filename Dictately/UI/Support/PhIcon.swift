import SwiftUI
import CoreText

/// Phosphor 图标库接入（TASK-141，2026-10-13 用户裁决采用 Phosphor Icons，MIT）。
/// 字体位于 `Resources/Fonts/Phosphor/`（Regular + Bold 两字重起步，单字重 ≈490KB），
/// `.process("Resources")` 与 build.sh 拷贝双通道（Sounds 先例）；codepoint 取自
/// @phosphor-icons/web 2.1.2 各字重 CSS（跨字重同码点），落码为常量。
/// 站内首例图标字体——此前图标一律内联 SF Symbols；后续页面逐步替换不另行裁决。
enum PhIconName: String, CaseIterable {
    /// 动作栏「使用」。
    case arrowCircleRight = "arrow-circle-right"
    /// 动作栏「下载」。
    case downloadSimple = "download-simple"
    /// 动作栏「删除」。
    case trashSimple = "trash-simple"
    /// 确认弹窗头部（含竖杠桶身，bold 字重）。
    case trash = "trash"
    /// 卡片资源行（内存/磁盘）。
    case cpu = "cpu"
    /// 槽位图章「使用中」对勾（TASK-149，bold 字重渲染）。
    case check = "check"
    /// 供应商卡钥匙徽「已配置/未配置」（TASK-149）。
    case key = "key"

    var codepoint: UInt32 {
        switch self {
        case .arrowCircleRight: return 0xE02E
        case .downloadSimple: return 0xE20C
        case .trash: return 0xE4A6
        case .trashSimple: return 0xE4A8
        case .cpu: return 0xE610
        case .check: return 0xE182
        case .key: return 0xE2D6
        }
    }
}

/// 字重 → 字体族。TTF 内部族名与 @phosphor-icons/web CSS 命名一致（各字重
/// 独立家族、Subfamily 均 Regular，fonttools 实测），`.custom` 直接按族名命中。
enum PhIconWeight: String, CaseIterable {
    case regular
    case bold

    var fontFamily: String {
        switch self {
        case .regular: return "Phosphor"
        case .bold: return "Phosphor-Bold"
        }
    }

    var resourceName: String {
        switch self {
        case .regular: return "Phosphor"
        case .bold: return "Phosphor-Bold"
        }
    }
}

/// 字体注册：进程级注册一次（CTFontManagerScope.process），幂等
/// （alreadyRegistered 视为成功）。惰性触发——首个 PhIcon 渲染时执行。
enum PhosphorFonts {
    static func fontURL(for weight: PhIconWeight, in bundle: Bundle = AppResources.bundle) -> URL? {
        // SPM `.process` 对子目录可能打平：先查包根，再查 Fonts/Phosphor/（Sounds 先例）
        return bundle.url(forResource: weight.resourceName, withExtension: "ttf")
            ?? bundle.url(forResource: weight.resourceName, withExtension: "ttf", subdirectory: "Fonts/Phosphor")
    }

    @discardableResult
    static func register(bundle: Bundle = AppResources.bundle) -> Bool {
        var success = true
        for weight in PhIconWeight.allCases {
            guard let url = fontURL(for: weight, in: bundle) else {
                success = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Swift 桥接：成功返回 Bool，失败细节经 CFError 传出；已注册视为幂等成功
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    success = false
                }
            }
        }
        return success
    }

    private static let _ensureRegistered: Bool = register()
    static func ensureRegistered() { _ = _ensureRegistered }
}

/// 单色 Phosphor 图标：Text 渲染字形，前景色随 `.foregroundStyle` tint，
/// 与 SF Symbols 同样的「图标即文字」用法。
struct PhIcon: View {
    let name: PhIconName
    var weight: PhIconWeight = .regular
    let size: CGFloat

    var body: some View {
        PhosphorFonts.ensureRegistered()
        return Text(verbatim: glyph)
            .font(.custom(weight.fontFamily, size: size))
    }

    private var glyph: String {
        guard let scalar = Unicode.Scalar(name.codepoint) else { return "" }
        return String(Character(scalar))
    }
}
