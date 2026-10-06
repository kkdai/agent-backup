import Foundation

/// GitHub Copilot CLI (`~/.copilot`), following GitHub's configuration directory reference
/// (docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference).
///
/// Backed up: `settings.json`, `mcp-config.json`, `lsp-config.json`, `providers.json`,
/// `copilot-instructions.md`, `instructions/`, `agents/`, `skills/`, `hooks/`, `extensions/`,
/// plus `session-state/` and `command-history-state/` so history isn't lost.
///
/// Never backed up: `config.json` (auth tokens), `permissions-config.json`, `mcp-oauth-config/`,
/// `mcp-secrets/`, `session-store.db`, logs, IDE state and installed plugins.
///
/// GitHub lists session data as not portable and Copilot's session index isn't documented, so
/// sessions are restored only where they don't exist and the user is told `/resume` may not list them.
public struct CopilotProvider: AgentProvider {
    public let id = "copilot-cli"
    public let displayName = "GitHub Copilot CLI"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var copilotDir: URL { home.appendingPathComponent(".copilot", isDirectory: true) }

    static let files: [(String, ItemKind)] = [
        ("settings.json", .settings),
        ("mcp-config.json", .mcpConfig),
        ("lsp-config.json", .settings),
        ("providers.json", .settings),
        ("copilot-instructions.md", .instructions),
    ]
    static let trees: [(String, ItemKind)] = [
        ("instructions", .instructions),
        ("agents", .subagent),
        ("skills", .skill),
        ("hooks", .settings),
        ("extensions", .settings),
        ("session-state", .session),
        ("command-history-state", .history),
    ]

    public func isInstalled() -> Bool { fileExists(copilotDir) }

    public func collect() throws -> [CollectedFile] {
        var out: [CollectedFile] = []
        for (name, kind) in Self.files {
            let url = copilotDir.appendingPathComponent(name)
            if fileExists(url) {
                out.append(CollectedFile(kind: kind, path: ".copilot/\(name)", modifiedAt: modificationDate(url), source: .file(url)))
            }
        }
        for (dir, kind) in Self.trees {
            for file in walkFiles(copilotDir.appendingPathComponent(dir)) {
                // One session per folder; count its event log as the session, the rest as attachments.
                let itemKind: ItemKind = kind == .session && !file.path.hasSuffix("events.jsonl") ? .sessionArtifact : kind
                out.append(CollectedFile(kind: itemKind, path: ".copilot/\(dir)/\(file.path)",
                                         modifiedAt: modificationDate(file.url), source: .file(file.url)))
            }
        }
        return out
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
            agentID: id, displayName: displayName, projectCount: 0,
            sessionCount: files.filter { $0.kind == .session }.count,
            totalBytes: bytesByKind.values.reduce(0, +), bytesByKind: bytesByKind,
            mcpServers: AgentCatalog.jsonMCP(copilotDir.appendingPathComponent("mcp-config.json"))
        )
    }

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        var hasSessions = false
        for item in items {
            let target = home.appendingPathComponent(item.path)
            let data = context.mapper.rewrite(try await context.load(item))
            if item.path == ".copilot/mcp-config.json" || item.path == ".copilot/settings.json" {
                plan.writes.append(try planSettingsMerge(data, target: target, policy: context.policy, notes: &plan.notes))
                continue
            }
            let isSessionData = item.path.hasPrefix(".copilot/session-state/") || item.path.hasPrefix(".copilot/command-history-state/")
            hasSessions = hasSessions || item.kind == .session
            // Never overwrite live session data on this Mac.
            plan.writes.append(planFileWrite(target: target, data: data, kind: item.kind, modifiedAt: item.modifiedAt,
                                             policy: isSessionData ? .keep : context.policy, appendOnly: isSessionData))
        }
        if hasSessions { plan.notes.append(.sessionsMayNotBeListed(agent: displayName)) }
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        plan.notes.append(.logInAfterRestore(agent: displayName, command: "copilot"))
        return plan
    }
}
