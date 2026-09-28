// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoxSend",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BoxSend",
            path: "Sources/BoxSend"
        ),
        .testTarget(
            name: "BoxSendTests",
            dependencies: ["BoxSend"],
            path: "Tests/BoxSendTests"
        ),
    ]
)
