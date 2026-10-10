// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoxSend",
    platforms: [.macOS(.v13)],
    products: [
        // 动态库：产物名在三平台上都叫 boxsend（Windows boxsend.dll / macOS libboxsend.dylib），
        // 与 C# 侧 DllImport("boxsend") 的解析规则一致，打包时不需要改名
        .library(name: "boxsend", type: .dynamic, targets: ["BoxSendBridge"]),
    ],
    targets: [
        // 核心库：HTTP/站点/转种流水线/下载器/Gist 同步/Web 控制台（CLI 与 GUI 共用）
        .target(
            name: "BoxSendKit",
            path: "Sources/BoxSendKit"
        ),
        // C ABI 导出层：Windows WPF 界面进程内调用核心库（Linux/macOS 上用于验证 ABI）
        .target(
            name: "BoxSendBridge",
            dependencies: ["BoxSendKit"],
            path: "Sources/BoxSendBridge"
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
