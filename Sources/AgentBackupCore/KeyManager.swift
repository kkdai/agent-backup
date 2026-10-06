import Foundation

/// Unlocks a backup location's data key and caches it in Keychain, so the passphrase
/// is asked once per Mac. Shared by the CLI and the app (same Keychain items).
public struct KeyManager {
    let secrets: SecretStore
    let cachesKeys: Bool

    public init(secrets: SecretStore = KeychainStore(), cachesKeys: Bool = true) {
        self.secrets = secrets
        self.cachesKeys = cachesKeys
    }

    static func account(_ keyfile: Keyfile) -> String { "vault-\(keyfile.fingerprint)" }

    public func cachedVault(for keyfile: Keyfile) -> Vault? {
        guard cachesKeys, let raw = secrets.get(Self.account(keyfile)) else { return nil }
        return Vault(rawKey: raw)
    }

    public func unlock(_ keyfile: Keyfile, passphrase: String) throws -> Vault {
        let vault = try Vault.unlock(keyfile, passphrase: passphrase)
        if cachesKeys { try? secrets.set(Self.account(keyfile), vault.rawKey) }
        return vault
    }

    /// Sets up a new backup location with this passphrase.
    public func create(in store: BackupStore, passphrase: String, iterations: Int = Vault.defaultIterations) async throws -> Vault {
        let (vault, keyfile) = try await BackupEngine.initialize(store, passphrase: passphrase, iterations: iterations)
        if cachesKeys { try? secrets.set(Self.account(keyfile), vault.rawKey) }
        return vault
    }

    public func forget(_ keyfile: Keyfile) {
        secrets.delete(Self.account(keyfile))
    }
}
