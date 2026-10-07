import Foundation

/// SPM 资源包（`Dictately_Dictately.bundle`）的自有定位器（TASK-125）。
///
/// 为什么不用 SPM 生成的 `Bundle.module`：其访问器（Swift 6.1 可执行目标模板，
/// `.build/…/DerivedSources/resource_bundle_accessor.swift`）只查两个位置——
/// ① `Bundle.main.bundleURL` 根目录：.app 根放 bundle 会被 codesign 以
/// 「unsealed contents present in the bundle root」拒签（目录与符号链接两态实测均 exit 1），
/// 位置上永远不可达；② 构建机 `.build` 绝对路径：只在开发机存在——开发机一切正常纯属
/// 该路径兜底掩盖，装到任何其他 Mac 上启动即 `fatalError`（Mac16,12 实机崩 + /tmp 隐藏
/// `.build` 复现，AGENTS §48）。
///
/// 本定位器多候选查找，覆盖四种运行形态，与工具链生成的模板解耦：
/// ① `.app`：`Bundle.main.resourceURL`（= Contents/Resources，build.sh 落位）
/// ② 裸跑：主模块二进制所在目录（`Bundle(for:)` 反查 `.build` 产物原位）
/// ③ 测试宿主（swift-testing）：主模块链入 xctest bundle，资源包在其上级目录
///    （`.build/<triple>/<config>/`，SPM 测试布局）
/// ④ `swift run` 兜底：`Bundle.main.bundleURL`（可执行文件旁）
enum AppResources {
    private final class BundleFinder {}

    static let bundle: Bundle = {
        let name = "Dictately_Dictately.bundle"
        let hostBundle = Bundle(for: BundleFinder.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            hostBundle.resourceURL?.appendingPathComponent(name),
            hostBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        let searched = candidates.compactMap { $0?.path }.joined(separator: "、")
        fatalError("AppResources: 找不到 \(name)（已查：\(searched)）——资源未随包，检查 build.sh 拷贝")
    }()
}
