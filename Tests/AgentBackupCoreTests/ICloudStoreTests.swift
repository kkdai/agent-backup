import Foundation
import Testing
@testable import AgentBackupCore

struct ICloudStoreTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString)")

    @Test func usesTheICloudDriveFolderWhenAvailable() async throws {
        #expect(LocalFolderStore.iCloudDrive(home: home) == nil)   // iCloud Drive off

        try FileManager.default.createDirectory(at: LocalFolderStore.iCloudDriveFolder(home: home), withIntermediateDirectories: true)
        let store = try #require(LocalFolderStore.iCloudDrive(home: home))
        #expect(store.displayName == "iCloud Drive › AgentBackup")
        #expect(store.root.path.hasSuffix("Library/Mobile Documents/com~apple~CloudDocs/AgentBackup"))

        _ = try await BackupEngine.initialize(store, passphrase: "passphrase", iterations: 1000)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("keyfile.json").path))
    }
}
