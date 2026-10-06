import Foundation

/// Claude Code (`~/.claude`, `~/.claude.json`).
///
/// Backed up: settings, CLAUDE.md, skills/commands/agents/output-styles, prompt history,
/// plugin list, MCP servers (user + per-project), and everything under `projects/`
/// (session transcripts, their attachments, auto-memory).
///
/// Never backed up: login state (`oauthAccount` and the rest of `~/.claude.json`, Keychain),
/// caches, telemetry, shell snapshots, running-session state, and `skills/synced`
/// (re-synced from claude.ai after login).
public struct ClaudeCodeProvider: AgentProvider {
    public let id = "claude-code"
    public let displayName = "Claude Code"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }

    static let homeFiles: [(String, ItemKind)] = [
        ("settings.json", .settings),
        ("CLAUDE.md", .instructions),
        ("history.jsonl", .history),
        ("plugins/installed_plugins.json", .pluginManifest),
        ("plugins/known_marketplaces.json", .pluginManifest),
    ]
    static let homeTrees: [(String, ItemKind)] = [
        ("skills", .skill),
        ("commands", .command),
        ("agents", .subagent),
        ("output-styles", .outputStyle),
    ]
    /// Per-project keys copied out of `~/.claude.json`. Everything else there is machine state or login.
    static let projectKeys = ["mcpServers", "allowedTools", "enabledMcpjsonServers", "disabledMcpjsonServers"]
    static let mcpExtractPath = ".claude.json"

    public func isInstalled() -> Bool {
        fileExists(claudeDir) || fileExists(claudeJSON)
    }

    // MARK: - Backup

    public func collect() throws -> [CollectedFile] {
        var out: [CollectedFile] = []

        for (rel, kind) in Self.homeFiles {
            let url = claudeDir.appendingPathComponent(rel)
            if fileExists(url) {
                out.append(CollectedFile(kind: kind, path: ".claude/\(rel)", modifiedAt: modificationDate(url), source: .file(url)))
            }
        }

        for (dir, kind) in Self.homeTrees {
            let excluded: Set<String> = dir == "skills" ? ["synced"] : []
            for file in walkFiles(claudeDir.appendingPathComponent(dir), excludingTopLevel: excluded) {
                out.append(CollectedFile(kind: kind, path: ".claude/\(dir)/\(file.path)",
                                         modifiedAt: modificationDate(file.url), source: .file(file.url)))
            }
        }

        if let extract = try mcpExtract() {
            out.append(CollectedFile(kind: .mcpConfig, path: Self.mcpExtractPath, modifiedAt: modificationDate(claudeJSON), source: .data(extract)))
        }

        for project in projects() {
            let dir = projectsDir.appendingPathComponent(project.dirName)
            for file in walkFiles(dir) {
                let kind: ItemKind =
                    if file.path.hasPrefix("memory/") { .memory }
                    else if !file.path.contains("/") && file.path.hasSuffix(".jsonl") { .session }
                    else { .sessionArtifact }
                out.append(CollectedFile(kind: kind, path: file.path, project: project,
                                         modifiedAt: modificationDate(file.url), source: .file(file.url)))
            }
        }
        return out
    }

    /// The MCP-related slice of `~/.claude.json`, or nil when there is nothing to keep.
    func mcpExtract() throws -> Data? {
        guard let root = readJSONObject(claudeJSON) else { return nil }
        var extract: [String: Any] = [:]
        if let servers = root["mcpServers"] as? [String: Any], !servers.isEmpty {
            extract["mcpServers"] = servers
        }
        var projects: [String: Any] = [:]
        for (path, value) in root["projects"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            let kept = entry.filter { key, value in
                Self.projectKeys.contains(key) && !((value as? [Any])?.isEmpty ?? (value as? [String: Any])?.isEmpty ?? false)
            }
            if !kept.isEmpty { projects[path] = kept }
        }
        if !projects.isEmpty { extract["projects"] = projects }
        return extract.isEmpty ? nil : try serializeJSON(extract)
    }

    /// Project directories with their original path recovered where possible.
    func projects() -> [ProjectRef] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        let known = knownProjectPaths()
        return names.sorted().compactMap { name in
            var isDir: ObjCBool = false
            let dir = projectsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let path = known.first { PathMapper.claudeProjectDirName(for: $0) == name } ?? cwdFromSessions(in: dir, dirName: name)
            return ProjectRef(dirName: name, path: path)
        }
    }

    private func knownProjectPaths() -> [String] {
        var paths = Set((readJSONObject(claudeJSON)?["projects"] as? [String: Any])?.keys.map { $0 } ?? [])
        if let history = try? String(contentsOf: claudeDir.appendingPathComponent("history.jsonl"), encoding: .utf8) {
            for line in history.split(separator: "\n") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let project = obj["project"] as? String {
                    paths.insert(project)
                }
            }
        }
        return paths.sorted()
    }

    /// The directory name is lossy (`a.b` and `a-b` both become `a-b`), so recover the real path
    /// from a transcript's `cwd` that encodes back to this directory name.
    private func cwdFromSessions(in dir: URL, dirName: String) -> String? {
        let transcripts = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
        for name in transcripts {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"cwd\"") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let cwd = obj["cwd"] as? String, PathMapper.claudeProjectDirName(for: cwd) == dirName {
                    return cwd
                }
            }
        }
        return nil
    }

    public func summary() throws -> AgentSummary {
        let files = try collect()
        var servers: [MCPServerInfo] = []
        if let root = readJSONObject(claudeJSON) {
            for (name, config) in (root["mcpServers"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                servers.append(MCPServerInfo(name: name, project: nil, config: config as? [String: Any] ?? [:]))
            }
            for (path, entry) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let projectServers = (entry as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
                for (name, config) in projectServers.sorted(by: { $0.key < $1.key }) {
                    servers.append(MCPServerInfo(name: name, project: path, config: config as? [String: Any] ?? [:]))
                }
            }
        }
        var bytesByKind: [ItemKind: Int] = [:]
        for file in files {
            let size = switch file.source {
            case .file(let url): (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            case .data(let data): data.count
            }
            bytesByKind[file.kind, default: 0] += size
        }
        return AgentSummary(
            agentID: id, displayName: displayName,
            projectCount: Set(files.compactMap(\.project)).count,
            sessionCount: files.filter { $0.kind == .session }.count,
            totalBytes: bytesByKind.values.reduce(0, +), bytesByKind: bytesByKind, mcpServers: servers
        )
    }

    // MARK: - Restore

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        var pluginItems: [SnapshotItem] = []

        for item in items {
            switch item.kind {
            case .mcpConfig:
                let extract = context.mapper.rewrite(try await context.load(item))
                let (write, conflicts) = try planClaudeJSONMerge(extract: extract, policy: context.policy, modifiedAt: item.modifiedAt)
                plan.writes.append(write)
                plan.notes += conflicts
            case .history:
                let incoming = context.mapper.rewrite(try await context.load(item))
                plan.writes.append(planJSONLMerge(incoming: incoming, target: home.appendingPathComponent(item.path),
                                                  timestampKey: "timestamp", kind: .history))
            case .pluginManifest:
                pluginItems.append(item)
            default:
                let data = context.mapper.rewrite(try await context.load(item))
                plan.writes.append(planFileWrite(
                    target: target(for: item, mapper: context.mapper), data: data, kind: item.kind,
                    modifiedAt: item.modifiedAt, policy: context.policy, appendOnly: item.kind == .session
                ))
            }
        }

        plan.notes += try await pluginNotes(pluginItems, context: context)
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        plan.notes.append(.logInAfterRestore(agent: displayName, command: "claude"))
        return plan
    }

    func target(for item: SnapshotItem, mapper: PathMapper) -> URL {
        guard let project = item.project else { return home.appendingPathComponent(item.path) }
        let dirName = project.path.map { PathMapper.claudeProjectDirName(for: mapper.map(path: $0)) }
            ?? mapper.mapClaudeProjectDirName(project.dirName)
        return projectsDir.appendingPathComponent(dirName).appendingPathComponent(item.path)
    }

    /// Merges MCP servers server-by-server into this Mac's `~/.claude.json`, leaving every other key alone.
    func planClaudeJSONMerge(extract: Data, policy: ConflictPolicy, modifiedAt: Date?) throws -> (PlannedWrite, [RestoreNote]) {
        let incoming = (try JSONSerialization.jsonObject(with: extract) as? [String: Any]) ?? [:]
        let existing = readJSONObject(claudeJSON)
        var root = existing ?? [:]
        var conflicts: [RestoreNote] = []

        func mergeServers(_ servers: [String: Any], into current: [String: Any], scope: String) -> [String: Any] {
            mergeMCPServers(servers, into: current, scope: scope == "user" ? nil : scope, policy: policy, conflicts: &conflicts)
        }

        if let servers = incoming["mcpServers"] as? [String: Any] {
            root["mcpServers"] = mergeServers(servers, into: root["mcpServers"] as? [String: Any] ?? [:], scope: "user")
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        for (path, value) in incoming["projects"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            var local = projects[path] as? [String: Any] ?? [:]
            if let servers = entry["mcpServers"] as? [String: Any] {
                local["mcpServers"] = mergeServers(servers, into: local["mcpServers"] as? [String: Any] ?? [:], scope: path)
            }
            for key in Self.projectKeys where key != "mcpServers" {
                guard let values = entry[key] as? [String] else { continue }
                let current = local[key] as? [String] ?? []
                local[key] = current + values.filter { !current.contains($0) }
            }
            projects[path] = local
        }
        if !projects.isEmpty { root["projects"] = projects }

        let data = try serializeJSON(root)
        let action: PlannedWrite.Action =
            existing == nil ? .create
            : NSDictionary(dictionary: existing!).isEqual(to: root) ? .unchanged : .update
        let write = PlannedWrite(target: claudeJSON, data: data, kind: .mcpConfig, action: action,
                                 detail: "merged MCP servers into ~/.claude.json", modifiedAt: nil)
        return (write, conflicts)
    }

    /// Plugins are restored as instructions: copying the plugin cache across machines isn't safe.
    func pluginNotes(_ items: [SnapshotItem], context: RestoreContext) async throws -> [RestoreNote] {
        var notes: [RestoreNote] = []
        for item in items {
            guard let root = try JSONSerialization.jsonObject(with: try await context.load(item)) as? [String: Any] else { continue }
            if item.path.hasSuffix("known_marketplaces.json") {
                for (name, value) in root.sorted(by: { $0.key < $1.key }) where name != "claude-plugins-official" {
                    let source = (value as? [String: Any])?["source"] as? [String: Any]
                    if let repo = source?["repo"] as? String ?? source?["url"] as? String {
                        notes.append(.readdMarketplace(repo: repo))
                    }
                }
            } else if let plugins = root["plugins"] as? [String: Any] {
                for name in plugins.keys.sorted() {
                    notes.append(.reinstallPlugin(name: name))
                }
            }
        }
        return notes
    }
}
