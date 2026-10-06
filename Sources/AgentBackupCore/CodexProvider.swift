import Foundation

/// OpenAI Codex CLI (`~/.codex`).
///
/// Backed up: `config.toml` (MCP servers, profiles, trusted projects), `AGENTS.md`,
/// `prompts/`, `skills/` (minus bundled `.system`), `memories/`, `rules/`,
/// prompt `history.jsonl`, and session rollouts in `sessions/` and `archived_sessions/`.
///
/// Never backed up: `auth.json` (login), the SQLite index and logs, caches, plugin and
/// vendor downloads, `computer-use`, temp files.
///
/// Codex lists sessions from its SQLite index, which it only rebuilds from rollout files
/// while `backfill_state` isn't complete. Restoring sessions therefore marks the backfill
/// pending again, so Codex re-indexes on next start (it upserts and keeps existing titles).
public struct CodexProvider: AgentProvider {
    public let id = "codex"
    public let displayName = "Codex CLI"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var codexDir: URL { home.appendingPathComponent(".codex", isDirectory: true) }

    static let files: [(String, ItemKind)] = [
        ("config.toml", .settings),
        ("AGENTS.md", .instructions),
        ("history.jsonl", .history),
    ]
    static let trees: [(String, ItemKind, Set<String>)] = [
        ("prompts", .command, []),
        ("skills", .skill, [".system"]),
        ("memories", .memory, []),
        ("rules", .settings, []),
        ("sessions", .session, []),
        ("archived_sessions", .session, []),
    ]

    public func isInstalled() -> Bool { fileExists(codexDir) }

    // MARK: - Backup

    public func collect() throws -> [CollectedFile] {
        var out: [CollectedFile] = []
        for (name, kind) in Self.files {
            let url = codexDir.appendingPathComponent(name)
            if fileExists(url) {
                out.append(CollectedFile(kind: kind, path: ".codex/\(name)", modifiedAt: modificationDate(url), source: .file(url)))
            }
        }
        for (dir, kind, excluded) in Self.trees {
            for file in walkFiles(codexDir.appendingPathComponent(dir), excludingTopLevel: excluded) {
                let isRollout = kind == .session && file.path.contains("rollout-")
                // Only rollouts are sessions; anything else in those folders is supporting data.
                let itemKind: ItemKind = kind == .session && !isRollout ? .sessionArtifact : kind
                let cwd = isRollout ? Self.sessionCwd(file.url) : nil
                out.append(CollectedFile(
                    kind: itemKind, path: ".codex/\(dir)/\(file.path)",
                    project: cwd.map { ProjectRef(dirName: "", path: $0) },
                    modifiedAt: modificationDate(file.url), source: .file(file.url)
                ))
            }
        }
        return out
    }

    /// `cwd` from the rollout's `session_meta` line, so the restore wizard can map its project.
    static func sessionCwd(_ url: URL) -> String? {
        guard url.pathExtension == "jsonl", let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n").prefix(20) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String { return cwd }
        }
        return nil
    }

    public func summary() throws -> AgentSummary {
        let files = try collect()
        var bytesByKind: [ItemKind: Int] = [:]
        for file in files {
            if case .file(let url) = file.source {
                bytesByKind[file.kind, default: 0] += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
        }
        return AgentSummary(
            agentID: id, displayName: displayName,
            projectCount: Set(files.compactMap { $0.project?.path }).count,
            sessionCount: files.filter { $0.kind == .session }.count,
            totalBytes: bytesByKind.values.reduce(0, +), bytesByKind: bytesByKind,
            mcpServers: AgentCatalog.codexMCP(codexDir.appendingPathComponent("config.toml"))
        )
    }

    // MARK: - Restore

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        var restoresSessions = false

        for item in items {
            let target = home.appendingPathComponent(item.path)
            let raw = try await context.load(item)
            // Compressed rollouts (.zst) can't be rewritten; they're restored as-is.
            let data = item.path.hasSuffix(".zst") ? raw : context.mapper.rewrite(raw)
            switch item.kind {
            case .history:
                plan.writes.append(planJSONLMerge(incoming: data, target: target, timestampKey: "ts", kind: .history))
            case .session:
                let write = planFileWrite(target: target, data: data, kind: .session, modifiedAt: item.modifiedAt,
                                          policy: context.policy, appendOnly: true)
                restoresSessions = restoresSessions || write.writes
                plan.writes.append(write)
            default:
                plan.writes.append(planFileWrite(target: target, data: data, kind: item.kind,
                                                 modifiedAt: item.modifiedAt, policy: context.policy))
            }
        }

        if restoresSessions {
            plan.postActions += indexDatabases().map { .reindexCodexSessions(database: $0) }
        }
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        plan.notes.append(.logInAfterRestore(agent: displayName, command: "codex login"))
        return plan
    }

    /// `state_<n>.sqlite` files that have a backfill table (the version number changes across Codex releases).
    /// None on a fresh Mac — Codex then indexes everything on first start anyway.
    func indexDatabases() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        return names.filter { $0.hasPrefix("state") && $0.hasSuffix(".sqlite") }.sorted()
            .map { codexDir.appendingPathComponent($0) }
            .filter { sqliteHasTable($0, "backfill_state") }
    }
}
