// swift-tools-version: 5.10
import PackageDescription

// C ABI 导出符号清单：与 Sources/BoxSendBridge/Exports.swift 里的 @_cdecl 一一对应
let cdeclExports = [
    "boxsend_create", "boxsend_invoke", "boxsend_free", "boxsend_set_ocr",
    "boxsend_version", "boxsend_destroy", "boxsend_last_error",
]

// Windows 的 DLL 靠 COFF 导出表对外露名字，而 COFF 只认 .drectve / .def 这两种自动写法，
// Swift 的 @_cdecl 都不走：它只保证符号名，不保证进导出表。这里把名单显式交给链接器，
// windows/build.ps1 打包前会解析导出表核对一遍（漏的名字要撑到用户开机才露脸）。
// Mach-O / ELF 不需要，导出表由 public 可见性自动决定。
let bridgeLinkerSettings: [LinkerSetting] = cdeclExports.map {
    .unsafeFlags(["-Xlinker", "/EXPORT:\($0)"], .when(platforms: [.windows]))
}

let package = Package(
    name: "BoxSend",
    platforms: [.macOS(.v13)],
    products: [
        // 动态库：Windows 得 boxsend-core.dll、macOS 得 libboxsend-core.dylib。
        // 名字特意带上 -core：Windows 文件名不分大小写，核心库若叫 boxsend.dll 会和 WPF
        // 那份托管程序集 BoxSend.dll 撞成一个，界面加载到的是自己，报「Unable to find an
        // entry point named 'boxsend_create' in DLL 'boxsend'」——还不发生在 mac 上。
        .library(name: "boxsend-core", type: .dynamic, targets: ["BoxSendBridge"]),
    ],
    targets: [
        // 核心库：HTTP/站点/转种流水线/下载器/Gist 同步/Web 控制台（CLI 与 GUI 共用）
        .target(
            name: "BoxSendKit",
            path: "Sources/BoxSendKit",
            // 内置 HTTP 服务在 Windows 上走 Winsock，得显式链 ws2_32；其余平台不加
            linkerSettings: [
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            ]
        ),
        // C ABI 导出层：Windows WPF 界面进程内调用核心库（Linux/macOS 上用于验证 ABI）
        .target(
            name: "BoxSendBridge",
            dependencies: ["BoxSendKit"],
            path: "Sources/BoxSendBridge",
            linkerSettings: bridgeLinkerSettings
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
            path: "Tests/BoxSendTests",
            // 夹具按 #filePath 从源码目录读，不需要 SwiftPM 当资源拷一遍
            exclude: ["Fixtures"]
        ),
    ]
)
