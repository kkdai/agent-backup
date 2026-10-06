import Foundation

/// Where backups are kept. Stores only see opaque, already-encrypted bytes.
///
/// Layout (identical on disk and on Google Drive):
/// ```
/// AgentBackup/
///   keyfile.json          passphrase-wrapped data key
///   snapshots/<id>        encrypted manifest; <id> starts with a UTC timestamp, so IDs sort by time
///   blobs/<hmac>          encrypted file contents, shared across snapshots
/// ```
public protocol BackupStore {
    /// Shown to the user, e.g. a folder path or "Google Drive".
    var displayName: String { get }

    func keyfile() async throws -> Data?
    /// Creates the keyfile; fails if one exists.
    func putKeyfile(_ data: Data) async throws
    /// Overwrites the existing keyfile (passphrase change).
    func replaceKeyfile(_ data: Data) async throws

    func blobIDs() async throws -> Set<String>
    func putBlob(_ id: String, _ data: Data) async throws
    func blob(_ id: String) async throws -> Data

    func snapshotIDs() async throws -> [String]
    func putSnapshot(_ id: String, _ data: Data) async throws
    func snapshot(_ id: String) async throws -> Data
}

public enum BackupError: LocalizedError, Equatable {
    case snapshotNotFound(String)
    case noSnapshots
    case notInitialized
    case keyfileExists
    case keyfileVerificationFailed
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound(let id): "Snapshot \(id) not found."
        case .noSnapshots: "No snapshots in this backup location."
        case .notInitialized: "This location has no backup yet (no keyfile.json)."
        case .keyfileExists: "This location already has a keyfile."
        case .keyfileVerificationFailed: "The new keyfile could not be verified; the passphrase was not changed."
        case .unsupportedFormat(let v): "Snapshot format \(v) is newer than this app supports."
        }
    }
}

public final class LocalFolderStore: BackupStore {
    public let root: URL
    private let fm = FileManager.default

    public init(folder: URL) {
        root = folder.appendingPathComponent("AgentBackup", isDirectory: true)
    }

    public var displayName: String { root.path }

    private var keyfileURL: URL { root.appendingPathComponent("keyfile.json") }
    private var blobsDir: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private var snapshotsDir: URL { root.appendingPathComponent("snapshots", isDirectory: true) }

    private func blobURL(_ id: String) -> URL {
        blobsDir.appendingPathComponent("\(id.prefix(2))/\(id)")
    }

    private func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func keyfile() async throws -> Data? {
        try? Data(contentsOf: keyfileURL)
    }

    public func putKeyfile(_ data: Data) async throws {
        guard !fm.fileExists(atPath: keyfileURL.path) else { throw BackupError.keyfileExists }
        try write(data, to: keyfileURL)
    }

    public func replaceKeyfile(_ data: Data) async throws {
        guard fm.fileExists(atPath: keyfileURL.path) else { throw BackupError.notInitialized }
        try write(data, to: keyfileURL)
    }

    public func blobIDs() async throws -> Set<String> {
        let prefixes = (try? fm.contentsOfDirectory(atPath: blobsDir.path)) ?? []
        return Set(prefixes.flatMap { (try? fm.contentsOfDirectory(atPath: blobsDir.appendingPathComponent($0).path)) ?? [] })
    }

    public func putBlob(_ id: String, _ data: Data) async throws {
        try write(data, to: blobURL(id))
    }

    public func blob(_ id: String) async throws -> Data {
        try Data(contentsOf: blobURL(id))
    }

    public func snapshotIDs() async throws -> [String] {
        ((try? fm.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    public func putSnapshot(_ id: String, _ data: Data) async throws {
        try write(data, to: snapshotsDir.appendingPathComponent(id))
    }

    public func snapshot(_ id: String) async throws -> Data {
        let url = snapshotsDir.appendingPathComponent(id)
        guard fm.fileExists(atPath: url.path) else { throw BackupError.snapshotNotFound(id) }
        return try Data(contentsOf: url)
    }
}

enum ManifestCoding {
    static func encode(_ manifest: Manifest) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(manifest)
    }

    static func decode(_ data: Data) throws -> Manifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let manifest = try d.decode(Manifest.self, from: data)
        if manifest.formatVersion > Manifest.currentFormatVersion {
            throw BackupError.unsupportedFormat(manifest.formatVersion)
        }
        return manifest
    }
}
