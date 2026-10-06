import CryptoKit
import Foundation

/// Where snapshots are kept. M0 ships a local folder; Google Drive (M1) implements the same protocol.
public protocol BackupStore {
    func hasBlob(_ id: String) async throws -> Bool
    func putBlob(_ id: String, _ data: Data) async throws
    func blob(_ id: String) async throws -> Data
    func putManifest(_ manifest: Manifest) async throws
    func manifests() async throws -> [Manifest]
}

extension BackupStore {
    /// Newest first.
    public func manifest(id: String?) async throws -> Manifest {
        let all = try await manifests()
        if let id {
            guard let match = all.first(where: { $0.id == id }) else { throw BackupError.snapshotNotFound(id) }
            return match
        }
        guard let latest = all.first else { throw BackupError.noSnapshots }
        return latest
    }
}

public enum BackupError: LocalizedError, Equatable {
    case snapshotNotFound(String)
    case noSnapshots
    case blobCorrupted(String)
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound(let id): "Snapshot \(id) not found."
        case .noSnapshots: "No snapshots in this backup location."
        case .blobCorrupted(let id): "Blob \(id) failed its integrity check."
        case .unsupportedFormat(let v): "Snapshot format \(v) is newer than this app supports."
        }
    }
}

/// Layout: `<folder>/AgentBackup/{blobs/ab/<sha256>, snapshots/<id>.json}` — the same layout used on Google Drive.
public final class LocalFolderStore: BackupStore {
    public let root: URL
    private let fm = FileManager.default

    public init(folder: URL) {
        root = folder.appendingPathComponent("AgentBackup", isDirectory: true)
    }

    private func blobURL(_ id: String) -> URL {
        root.appendingPathComponent("blobs/\(id.prefix(2))/\(id)")
    }

    private var snapshotsDir: URL { root.appendingPathComponent("snapshots", isDirectory: true) }

    public func hasBlob(_ id: String) async throws -> Bool {
        fm.fileExists(atPath: blobURL(id).path)
    }

    public func putBlob(_ id: String, _ data: Data) async throws {
        let url = blobURL(id)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func blob(_ id: String) async throws -> Data {
        try Data(contentsOf: blobURL(id))
    }

    public func putManifest(_ manifest: Manifest) async throws {
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try ManifestCoding.encoder.encode(manifest)
            .write(to: snapshotsDir.appendingPathComponent("\(manifest.id).json"), options: .atomic)
    }

    public func manifests() async throws -> [Manifest] {
        guard let names = try? fm.contentsOfDirectory(atPath: snapshotsDir.path) else { return [] }
        return try names.filter { $0.hasSuffix(".json") }
            .map { try ManifestCoding.decode(Data(contentsOf: snapshotsDir.appendingPathComponent($0))) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

enum ManifestCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

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

/// Encodes blob bytes for storage. M1 adds encryption here, so stores only ever see opaque bytes.
public struct BlobCodec {
    private enum Header: UInt8 {
        case raw = 0
        case lzfse = 1
    }

    public init() {}

    public static func id(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func encode(_ data: Data) throws -> Data {
        if data.count >= 256, let compressed = try? (data as NSData).compressed(using: .lzfse) as Data,
           compressed.count < data.count {
            return Data([Header.lzfse.rawValue]) + compressed
        }
        return Data([Header.raw.rawValue]) + data
    }

    public func decode(_ stored: Data, expectedID: String) throws -> Data {
        guard let first = stored.first, let header = Header(rawValue: first) else {
            throw BackupError.blobCorrupted(expectedID)
        }
        let body = stored.dropFirst()
        let data: Data
        switch header {
        case .raw: data = Data(body)
        case .lzfse: data = try (Data(body) as NSData).decompressed(using: .lzfse) as Data
        }
        guard Self.id(for: data) == expectedID else { throw BackupError.blobCorrupted(expectedID) }
        return data
    }
}
