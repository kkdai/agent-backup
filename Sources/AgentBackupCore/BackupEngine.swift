import Foundation

public struct BackupResult {
    public var manifest: Manifest
    public var fileCount: Int
    public var newBlobCount: Int
    public var uploadedBytes: Int
}

public struct ApplyResult {
    public var written: Int
    public var rollbackDir: URL?
}

public struct BackupEngine {
    public let store: BackupStore
    let codec = BlobCodec()

    public init(store: BackupStore) {
        self.store = store
    }

    // MARK: - Backup

    public func backup(providers: [AgentProvider], source: SourceInfo, now: Date = Date()) async throws -> BackupResult {
        var agents: [AgentSnapshot] = []
        var fileCount = 0, newBlobs = 0, uploaded = 0
        var uploadedThisRun = Set<String>()

        for provider in providers where provider.isInstalled() {
            var items: [SnapshotItem] = []
            for file in try provider.collect() {
                let data = try file.read()
                let id = BlobCodec.id(for: data)
                if !uploadedThisRun.contains(id), !(try await store.hasBlob(id)) {
                    let encoded = try codec.encode(data)
                    try await store.putBlob(id, encoded)
                    newBlobs += 1
                    uploaded += encoded.count
                }
                uploadedThisRun.insert(id)
                items.append(SnapshotItem(kind: file.kind, path: file.path, project: file.project,
                                          blob: id, size: data.count, modifiedAt: file.modifiedAt))
            }
            fileCount += items.count
            agents.append(AgentSnapshot(agentID: provider.id, items: items))
        }

        // The manifest goes last, so an interrupted backup never leaves a snapshot pointing at missing blobs.
        let manifest = Manifest(id: Self.snapshotID(date: now, hostname: source.hostname), createdAt: now, source: source, agents: agents)
        try await store.putManifest(manifest)
        return BackupResult(manifest: manifest, fileCount: fileCount, newBlobCount: newBlobs, uploadedBytes: uploaded)
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
            try codec.decode(try await store.blob(item.blob), expectedID: item.blob)
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
