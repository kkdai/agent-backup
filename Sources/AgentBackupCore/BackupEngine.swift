import Foundation

public struct BackupResult {
    public var manifest: Manifest
    public var fileCount: Int
    public var newBlobCount: Int
    public var uploadedBytes: Int
}

public struct BackupProgress {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesUploaded: Int
}

/// Shared state of one backup's parallel uploads.
actor UploadTracker {
    private var known: Set<String>
    private let total: Int
    private var done = 0
    private var bytes = 0
    private(set) var newBlobs = 0

    init(stored: Set<String>, total: Int) {
        known = stored
        self.total = total
    }

    /// True if the caller should upload this blob (first to see it, and not already stored).
    func claim(_ id: String) -> Bool {
        guard known.insert(id).inserted else { return false }
        newBlobs += 1
        return true
    }

    func finished(uploadedBytes: Int) -> BackupProgress {
        done += 1
        bytes += uploadedBytes
        return progress
    }

    var progress: BackupProgress { BackupProgress(filesDone: done, filesTotal: total, bytesUploaded: bytes) }
}

public struct ApplyResult {
    public var written: Int
    public var rollbackDir: URL?
}

public struct BackupEngine {
    public let store: BackupStore
    public let vault: Vault

    public init(store: BackupStore, vault: Vault) {
        self.store = store
        self.vault = vault
    }

    // MARK: - Keys

    /// The location's keyfile, or nil if nothing has been backed up there yet.
    public static func keyfile(in store: BackupStore) async throws -> Keyfile? {
        try await store.keyfile().map(Keyfile.decode)
    }

    /// Creates the keyfile for a new backup location.
    public static func initialize(_ store: BackupStore, passphrase: String, iterations: Int = Vault.defaultIterations) async throws -> (Vault, Keyfile) {
        let (vault, keyfile) = try Vault.create(passphrase: passphrase, iterations: iterations)
        try await store.putKeyfile(try keyfile.encoded())
        return (vault, keyfile)
    }

    /// Re-wraps the same data key under a new passphrase, so every existing snapshot stays readable
    /// and the old passphrase stops working. Verifies before writing and after reading back.
    public static func changePassphrase(
        in store: BackupStore, current: String, new: String, iterations: Int = Vault.defaultIterations
    ) async throws -> (Vault, Keyfile) {
        guard let data = try await store.keyfile() else { throw BackupError.notInitialized }
        let vault = try Vault.unlock(try Keyfile.decode(data), passphrase: current)
        let keyfile = try vault.keyfile(passphrase: new, iterations: iterations)
        guard try Vault.unlock(keyfile, passphrase: new).rawKey == vault.rawKey else {
            throw BackupError.keyfileVerificationFailed
        }
        try await store.replaceKeyfile(try keyfile.encoded())
        guard let stored = try await store.keyfile(), try Keyfile.decode(stored) == keyfile else {
            throw BackupError.keyfileVerificationFailed
        }
        return (vault, keyfile)
    }

    // MARK: - Snapshots

    /// Newest first.
    public func manifests() async throws -> [Manifest] {
        var out: [Manifest] = []
        for id in try await store.snapshotIDs().sorted(by: >) {
            out.append(try await manifest(id: id))
        }
        return out
    }

    /// `nil` means the latest.
    public func manifest(id: String?) async throws -> Manifest {
        let latest = id == nil ? try await store.snapshotIDs().max() : nil
        guard let id = id ?? latest else { throw BackupError.noSnapshots }
        return try ManifestCoding.decode(vault.open(try await store.snapshot(id)))
    }

    // MARK: - Backup

    /// How many files are read, encrypted and uploaded at once.
    public static let defaultConcurrency = 6

    public func backup(
        providers: [AgentProvider], source: SourceInfo, now: Date = Date(),
        concurrency: Int = BackupEngine.defaultConcurrency,
        progress: ((BackupProgress) -> Void)? = nil
    ) async throws -> BackupResult {
        let collected = try providers.filter { $0.isInstalled() }.map { ($0.id, try $0.collect()) }
        let files = collected.flatMap { agent, files in files.map { (agent, $0) } }
        let tracker = UploadTracker(stored: try await store.blobIDs(), total: files.count)
        progress?(await tracker.progress)

        var items = [SnapshotItem?](repeating: nil, count: files.count)
        try await withThrowingTaskGroup(of: (Int, SnapshotItem).self) { group in
            var next = 0
            func enqueue() {
                let index = next
                let file = files[index].1
                next += 1
                group.addTask { [store, vault] in
                    let data = try file.read()
                    let id = vault.blobID(for: data)
                    var uploaded = 0
                    // Identical content is uploaded once, even when two files hash the same concurrently.
                    if await tracker.claim(id) {
                        let sealed = try vault.seal(data)
                        try await store.putBlob(id, sealed)
                        uploaded = sealed.count
                    }
                    progress?(await tracker.finished(uploadedBytes: uploaded))
                    return (index, SnapshotItem(kind: file.kind, path: file.path, project: file.project,
                                                blob: id, size: data.count, modifiedAt: file.modifiedAt))
                }
            }
            for _ in 0..<min(max(1, concurrency), files.count) { enqueue() }
            while let (index, item) = try await group.next() {
                items[index] = item
                if next < files.count { enqueue() }
            }
        }

        var agents: [AgentSnapshot] = []
        var offset = 0
        for (agent, agentFiles) in collected {
            agents.append(AgentSnapshot(agentID: agent, items: items[offset..<offset + agentFiles.count].compactMap { $0 }))
            offset += agentFiles.count
        }

        // The manifest goes last, so an interrupted backup never leaves a snapshot pointing at missing blobs.
        let manifest = Manifest(id: Self.snapshotID(date: now, hostname: source.hostname), createdAt: now, source: source, agents: agents)
        try await store.putSnapshot(manifest.id, try vault.seal(ManifestCoding.encode(manifest)))
        let totals = await tracker.progress
        return BackupResult(manifest: manifest, fileCount: files.count, newBlobCount: await tracker.newBlobs, uploadedBytes: totals.bytesUploaded)
    }

    /// Reads the time and device out of a snapshot ID — no decryption needed, so the UI can
    /// show "last backup" before the user unlocks anything.
    public static func parseSnapshotID(_ id: String) -> (date: Date, hostname: String)? {
        let parts = id.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = formatter.date(from: "\(parts[0])-\(parts[1])") else { return nil }
        return (date, parts[2].replacingOccurrences(of: "-", with: " "))
    }

    static func snapshotID(date: Date, hostname: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let host = String(hostname.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
        return "\(formatter.string(from: date))-\(host)"
    }

    // MARK: - Restore

    /// Builds a plan per agent; nothing is written. `extraRules` come before the default
    /// source-home → target-home rule (longest prefix wins either way).
    public func planRestore(
        manifest: Manifest, targetHome: URL, extraRules: [PathMapper.Rule] = [],
        policy: ConflictPolicy = .keep, agentIDs: Set<String>? = nil
    ) async throws -> [RestorePlan] {
        let mapper = PathMapper(rules: extraRules + [PathMapper.Rule(from: manifest.source.home, to: targetHome.path)])
        let context = RestoreContext(mapper: mapper, policy: policy) { item in
            try vault.open(try await store.blob(item.blob), expectedID: item.blob)
        }
        var plans: [RestorePlan] = []
        for agent in manifest.agents where agentIDs?.contains(agent.agentID) ?? true {
            guard let provider = Providers.provider(id: agent.agentID, home: targetHome) else {
                var plan = RestorePlan(agentID: agent.agentID)
                plan.notes.append(.unsupportedAgent(id: agent.agentID))
                plans.append(plan)
                continue
            }
            plans.append(try await provider.planRestore(items: agent.items, context: context))
        }
        return plans
    }

    /// Writes the plan. Every file it overwrites is first copied into a rollback point
    /// (see `RollbackPoint`), so the restore can be undone.
    public static func apply(_ plans: [RestorePlan], home: URL, now: Date = Date()) throws -> ApplyResult {
        let fm = FileManager.default
        let writes = plans.flatMap(\.writes).filter(\.writes)
        guard !writes.isEmpty else { return ApplyResult(written: 0, rollbackDir: nil) }

        let point = try RollbackPoint.create(home: home, date: now)
        var created: [String] = []
        for write in writes {
            if fm.fileExists(atPath: write.target.path) {
                let saved = point.savedCopy(of: write.target, home: home)
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: saved)
                try fm.copyItem(at: write.target, to: saved)
            } else {
                created.append(write.target.path)
            }
            try fm.createDirectory(at: write.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write.data.write(to: write.target, options: .atomic)
            if let date = write.modifiedAt {
                // Keeps `claude --resume` ordering sessions by when they actually happened.
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: write.target.path)
            }
            // Written after every file, so an interrupted restore can still be rolled back.
            try point.recordCreated(created)
        }
        return ApplyResult(written: writes.count, rollbackDir: point.url)
    }
}
