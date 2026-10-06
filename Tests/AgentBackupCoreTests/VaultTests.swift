import Foundation
import Testing
@testable import AgentBackupCore

struct VaultTests {
    @Test func sealsAndOpensWithCompression() throws {
        let vault = Vault(rawKey: Data(repeating: 1, count: 32))
        let data = Data(String(repeating: "session line\n", count: 500).utf8)
        let sealed = try vault.seal(data)
        #expect(sealed.count < data.count)
        #expect(try vault.open(sealed, expectedID: vault.blobID(for: data)) == data)
        #expect(try vault.open(try vault.seal(Data())) == Data())
    }

    @Test func rejectsTamperingAndWrongKeys() throws {
        let vault = Vault(rawKey: Data(repeating: 1, count: 32))
        var sealed = try vault.seal(Data("secret".utf8))
        #expect(throws: VaultError.self) { try Vault(rawKey: Data(repeating: 2, count: 32)).open(sealed) }
        sealed[sealed.count - 1] ^= 1
        #expect(throws: VaultError.self) { try vault.open(sealed) }
        #expect(throws: VaultError.self) { try vault.open(try vault.seal(Data("a".utf8)), expectedID: vault.blobID(for: Data("b".utf8))) }
    }

    @Test func blobIDsAreKeyed() {
        let data = Data("same content".utf8)
        #expect(Vault(rawKey: Data(repeating: 1, count: 32)).blobID(for: data)
            != Vault(rawKey: Data(repeating: 2, count: 32)).blobID(for: data))
    }

    @Test func keyfileUnlocksOnlyWithItsPassphrase() throws {
        let (vault, keyfile) = try Vault.create(passphrase: "correct horse", iterations: 1000)
        let decoded = try Keyfile.decode(try keyfile.encoded())
        #expect(try Vault.unlock(decoded, passphrase: "correct horse").rawKey == vault.rawKey)
        #expect(throws: VaultError.wrongPassphrase) { try Vault.unlock(decoded, passphrase: "wrong") }

        let rewrapped = try vault.keyfile(passphrase: "new passphrase", iterations: 1000)
        #expect(try Vault.unlock(rewrapped, passphrase: "new passphrase").rawKey == vault.rawKey)
        #expect(rewrapped.fingerprint != keyfile.fingerprint)
    }

    @Test func engineInitializesALocationOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        let store = LocalFolderStore(folder: dir)
        #expect(try await BackupEngine.keyfile(in: store) == nil)
        let (vault, _) = try await BackupEngine.initialize(store, passphrase: "pass phrase", iterations: 1000)
        let keyfile = try #require(try await BackupEngine.keyfile(in: store))
        #expect(try Vault.unlock(keyfile, passphrase: "pass phrase").rawKey == vault.rawKey)
    }
}
