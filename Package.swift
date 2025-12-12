// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DebugProbe",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "DebugProbe",
            targets: ["DebugProbe"]
        ),
    ],
    dependencies: [
        // CocoaLumberjack 为可选依赖
        // 如果宿主工程需要使用 DDLogBridge，需要在宿主工程中也添加 CocoaLumberjack 依赖
        // .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", from: "3.8.0"),
    ],
    targets: [
        .target(
            name: "DebugProbe",
            dependencies: [
                // CocoaLumberjack 为可选依赖，使用 #if canImport(CocoaLumberjack) 条件编译
            ],
            path: "Sources"
        ),
    ]
)
