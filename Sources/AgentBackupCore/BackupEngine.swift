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

    public func backup(
        providers: [AgentProvider], source: SourceInfo, now: Date = Date(),
        progress: ((BackupProgress) -> Void)? = nil
    ) async throws -> BackupResult {
        var agents: [AgentSnapshot] = []
        var fileCount = 0, newBlobs = 0, uploaded = 0
        var stored = try await store.blobIDs()

        let collected = try providers.filter { $0.isInstalled() }.map { ($0, try $0.collect()) }
        let total = collected.reduce(0) { $0 + $1.1.count }
        progress?(BackupProgress(filesDone: 0, filesTotal: total, bytesUploaded: 0))

        for (provider, files) in collected {
            var items: [SnapshotItem] = []
            for file in files {
                let data = try file.read()
                let id = vault.blobID(for: data)
                if !stored.contains(id) {
                    let sealed = try vault.seal(data)
                    try await store.putBlob(id, sealed)
                    stored.insert(id)
                    newBlobs += 1
                    uploaded += sealed.count
                }
                items.append(SnapshotItem(kind: file.kind, path: file.path, project: file.project,
                                          blob: id, size: data.count, modifiedAt: file.modifiedAt))
                progress?(BackupProgress(filesDone: fileCount + items.count, filesTotal: total, bytesUploaded: uploaded))
            }
            fileCount += items.count
            agents.append(AgentSnapshot(agentID: provider.id, items: items))
        }

        // The manifest goes last, so an interrupted backup never leaves a snapshot pointing at missing blobs.
        let manifest = Manifest(id: Self.snapshotID(date: now, hostname: source.hostname), createdAt: now, source: source, agents: agents)
        try await store.putSnapshot(manifest.id, try vault.seal(ManifestCoding.encode(manifest)))
        return BackupResult(manifest: manifest, fileCount: fileCount, newBlobCount: newBlobs, uploadedBytes: uploaded)
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
                plan.notes.append("This version of the app can't restore '\(agent.agentID)'; skipped.")
                plans.append(plan)
                continue
            }
            plans.append(try await provider.planRestore(items: agent.items, context: context))
        }
        return plans
    }

    /// Writes the plan. Every file it overwrites is first copied to
    /// `~/Library/Application Support/AgentBackup/rollback/<timestamp>/`, and newly created
    /// files are listed in `created-files.txt` there.
    public static func apply(_ plans: [RestorePlan], home: URL, now: Date = Date()) throws -> ApplyResult {
        let fm = FileManager.default
        let rollbackDir = home.appendingPathComponent("Library/Application Support/AgentBackup/rollback")
            .appendingPathComponent(snapshotID(date: now, hostname: "restore"))
        var written = 0
        var created: [String] = []

        for write in plans.flatMap(\.writes) where write.writes {
            if fm.fileExists(atPath: write.target.path) {
                let relative = write.target.path.hasPrefix(home.path + "/")
                    ? String(write.target.path.dropFirst(home.path.count + 1))
                    : write.target.lastPathComponent
                let saved = rollbackDir.appendingPathComponent(relative)
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
            written += 1
        }
        guard written > 0 else { return ApplyResult(written: 0, rollbackDir: nil) }
        // Files that didn't exist before; rolling back means deleting these.
        try fm.createDirectory(at: rollbackDir, withIntermediateDirectories: true)
        try Data((created.joined(separator: "\n") + "\n").utf8)
            .write(to: rollbackDir.appendingPathComponent("created-files.txt"))
        return ApplyResult(written: written, rollbackDir: rollbackDir)
    }
}
