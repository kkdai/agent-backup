import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for everything that leaves the Mac.
///
/// A random 256-bit data key encrypts every blob and manifest (AES-GCM). The data key
/// itself is stored in `AgentBackup/keyfile.json`, wrapped by a key derived from the
/// user's passphrase — so the storage provider only ever holds ciphertext, and the
/// passphrase can later be changed without re-encrypting the backup.
public struct Vault {
    private let dataKey: SymmetricKey
    private let encryptionKey: SymmetricKey
    private let idKey: SymmetricKey

    public init(rawKey: Data) {
        dataKey = SymmetricKey(data: rawKey)
        encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: dataKey, info: Data("agent-backup/encrypt/v1".utf8), outputByteCount: 32)
        idKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: dataKey, info: Data("agent-backup/blob-id/v1".utf8), outputByteCount: 32)
    }

    public var rawKey: Data { dataKey.withUnsafeBytes { Data($0) } }

    /// OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000

    public static func create(passphrase: String, iterations: Int = defaultIterations) throws -> (Vault, Keyfile) {
        let rawKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let kek = try deriveKeyEncryptionKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let wrapped = try AES.GCM.seal(rawKey, using: kek, authenticating: Keyfile.associatedData).combined!
        let keyfile = Keyfile(iterations: iterations, salt: salt, wrappedKey: wrapped)
        return (Vault(rawKey: rawKey), keyfile)
    }

    public static func unlock(_ keyfile: Keyfile, passphrase: String) throws -> Vault {
        guard keyfile.version == Keyfile.currentVersion, keyfile.kdf == Keyfile.kdfName else {
            throw VaultError.unsupportedKeyfile
        }
        let kek = try deriveKeyEncryptionKey(passphrase: passphrase, salt: keyfile.salt, iterations: keyfile.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: keyfile.wrappedKey)
            return Vault(rawKey: try AES.GCM.open(box, using: kek, authenticating: Keyfile.associatedData))
        } catch {
            throw VaultError.wrongPassphrase
        }
    }

    /// Re-wraps the same data key under a new passphrase.
    public func keyfile(passphrase: String, iterations: Int = defaultIterations) throws -> Keyfile {
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let kek = try Self.deriveKeyEncryptionKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let wrapped = try AES.GCM.seal(rawKey, using: kek, authenticating: Keyfile.associatedData).combined!
        return Keyfile(iterations: iterations, salt: salt, wrappedKey: wrapped)
    }

    /// Keyed, so the storage provider can't confirm a backup contains some known file.
    public func blobID(for data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: idKey).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sealing

    private enum Format: UInt8 {
        case aesGCMv1 = 1
    }

    private enum Compression: UInt8 {
        case none = 0
        case lzfse = 1
    }

    public func seal(_ data: Data) throws -> Data {
        var inner = Data([Compression.none.rawValue]) + data
        if data.count >= 256, let compressed = try? (data as NSData).compressed(using: .lzfse) as Data,
           compressed.count < data.count {
            inner = Data([Compression.lzfse.rawValue]) + compressed
        }
        return Data([Format.aesGCMv1.rawValue]) + (try AES.GCM.seal(inner, using: encryptionKey).combined!)
    }

    /// Decrypts and, when `expectedID` is given, verifies the content matches its blob ID.
    public func open(_ sealed: Data, expectedID: String? = nil) throws -> Data {
        guard sealed.first == Format.aesGCMv1.rawValue else { throw VaultError.corrupted(expectedID ?? "data") }
        let inner: Data
        do {
            inner = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.dropFirst()), using: encryptionKey)
        } catch {
            throw VaultError.corrupted(expectedID ?? "data")
        }
        guard let first = inner.first, let compression = Compression(rawValue: first) else {
            throw VaultError.corrupted(expectedID ?? "data")
        }
        let body = Data(inner.dropFirst())
        let data = switch compression {
        case .none: body
        case .lzfse: try (body as NSData).decompressed(using: .lzfse) as Data
        }
        if let expectedID, blobID(for: data) != expectedID { throw VaultError.corrupted(expectedID) }
        return data
    }

    // MARK: - KDF

    static func deriveKeyEncryptionKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.withMemoryRebound(to: Int8.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        &derived, derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

/// `AgentBackup/keyfile.json` — the passphrase-wrapped data key. Safe to store next to the backup.
public struct Keyfile: Codable, Equatable {
    static let currentVersion = 1
    static let kdfName = "pbkdf2-hmac-sha256"
    static let associatedData = Data("agent-backup/keyfile/v1".utf8)

    public var version: Int
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    public var wrappedKey: Data

    init(iterations: Int, salt: Data, wrappedKey: Data) {
        version = Self.currentVersion
        kdf = Self.kdfName
        self.iterations = iterations
        self.salt = salt
        self.wrappedKey = wrappedKey
    }

    /// Stable identifier for caching the unlocked key in Keychain.
    public var fingerprint: String {
        SHA256.hash(data: salt + wrappedKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Keyfile {
        try JSONDecoder().decode(Keyfile.self, from: data)
    }
}

public enum VaultError: LocalizedError, Equatable {
    case wrongPassphrase
    case unsupportedKeyfile
    case keyDerivationFailed
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase: "Wrong passphrase."
        case .unsupportedKeyfile: "This backup's keyfile is from a newer version of the app."
        case .keyDerivationFailed: "Key derivation failed."
        case .corrupted(let what): "\(what) could not be decrypted or failed its integrity check."
        }
    }
}
