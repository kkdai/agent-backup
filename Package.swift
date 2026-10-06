// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentBackup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBackupCore", targets: ["AgentBackupCore"]),
        .executable(name: "agent-backup", targets: ["agent-backup"]),
        .executable(name: "AgentBackupApp", targets: ["AgentBackupApp"]),
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
        .executableTarget(name: "AgentBackupApp", dependencies: ["AgentBackupCore"]),
        .testTarget(name: "AgentBackupCoreTests", dependencies: ["AgentBackupCore"]),
    ],
    swiftLanguageModes: [.v5]
)
