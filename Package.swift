// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentBackup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBackupCore", targets: ["AgentBackupCore"]),
        .executable(name: "agent-backup", targets: ["agent-backup"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AgentBackupCore"),
        .executableTarget(
            name: "agent-backup",
            dependencies: [
                "AgentBackupCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AgentBackupCoreTests", dependencies: ["AgentBackupCore"]),
    ],
    swiftLanguageModes: [.v5]
)
