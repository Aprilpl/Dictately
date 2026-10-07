// swift-tools-version:6.0
// CLT-only 构建路线：无 .xcodeproj / 无 XcodeGen / 无 Xcode 依赖。
// App 壳由 scripts/build.sh 用 swift build 产物手工拼装 .app 并 ad-hoc 签名。
// 注：CLT 工具链不含 XCTest，测试用 swift-testing；语言模式保持 Swift 5。
import Foundation
import PackageDescription

// 公开仓库不含 DictatelyTests/（.gitignore「开源分发边界」，本地磁盘保留）；
// 目录存在才声明 testTarget——公开克隆 swift build / swift test 均不报
// 「找不到目录」硬错误（本地 swift test 行为不变）。
let hasTestSuite = FileManager.default.fileExists(atPath: "DictatelyTests")

let package = Package(
    name: "Dictately",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // 唯一第三方运行时依赖：GRDB.swift（SQLite 封装）
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3")
    ],
    targets: [
        .executableTarget(
            name: "Dictately",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Dictately",
            exclude: [
                "Info.plist",   // .app bundle 模板，由 build.sh 拷入 Contents/
            ],
            resources: [
                // 本地化文案经 SPM process 进 Bundle.module（代码用 bundle: .module 取，
                // 不依赖 Bundle.main——测试进程与分发场景同样可用）
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ] + (hasTestSuite ? [
        .testTarget(
            name: "DictatelyTests",
            dependencies: ["Dictately"],
            path: "DictatelyTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ] : [])
)
