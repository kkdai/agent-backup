import Foundation
import Testing
@testable import AgentBackupCore

struct PassphraseChangeTests {
    func exercise(_ store: BackupStore) async throws {
        let keys = KeyManager(secrets: MemorySecretStore())
        let original = try await keys.create(in: store, passphrase: "old passphrase", iterations: 1000)
        let sealed = try original.seal(Data("snapshot".utf8))

        await #expect(throws: VaultError.wrongPassphrase) {
            _ = try await keys.changePassphrase(in: store, current: "not it", new: "new passphrase", iterations: 1000)
        }
        _ = try await keys.changePassphrase(in: store, current: "old passphrase", new: "new passphrase", iterations: 1000)

        let keyfile = try #require(try await BackupEngine.keyfile(in: store))
        #expect(throws: VaultError.wrongPassphrase) { try Vault.unlock(keyfile, passphrase: "old passphrase") }
        let reopened = try Vault.unlock(keyfile, passphrase: "new passphrase")
        #expect(try reopened.open(sealed) == Data("snapshot".utf8))   // old data still readable
        #expect(keys.cachedVault(for: keyfile)?.rawKey == original.rawKey)
    }

    @Test func localFolder() async throws {
        try await exercise(LocalFolderStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")))
    }

    @Test func googleDrive() async throws {
        let drive = FakeDrive()
        try await exercise(GoogleDriveStore(tokens: StaticTokens(), http: drive, sleep: { _ in }))
        #expect(drive.files.values.filter { $0.name == "keyfile.json" }.count == 1)
    }

    @Test func createRefusesToOverwrite() async throws {
        let store = LocalFolderStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)"))
        _ = try await BackupEngine.initialize(store, passphrase: "first one", iterations: 1000)
        await #expect(throws: BackupError.keyfileExists) {
            _ = try await BackupEngine.initialize(store, passphrase: "second one", iterations: 1000)
        }
    }
}
