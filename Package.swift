// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoxSend",
    platforms: [.macOS(.v13)],
    targets: [
        // 核心库：HTTP/站点/转种流水线/下载器/Gist 同步/Web 控制台（CLI 与 GUI 共用）
        .target(
            name: "BoxSendKit",
            path: "Sources/BoxSendKit"
        ),
        // 命令行（launchd/自动化）
        .executableTarget(
            name: "box-send",
            dependencies: ["BoxSendKit"],
            path: "Sources/BoxSendCLI"
        ),
        // macOS GUI 应用（主体）
        .executableTarget(
            name: "BoxSendApp",
            dependencies: ["BoxSendKit"],
            path: "Sources/BoxSendApp"
        ),
        .testTarget(
            name: "BoxSendTests",
            dependencies: ["BoxSendKit"],
            path: "Tests/BoxSendTests"
        ),
    ]
)
