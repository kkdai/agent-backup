import Foundation

/// Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`).
///
/// Only the config file travels: MCP servers and app preferences. Conversations live in the
/// cloud and come back on login; desktop extensions are reinstalled from the app.
public struct ClaudeDesktopProvider: AgentProvider {
    public let id = "claude-desktop"
    public let displayName = "Claude Desktop"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    static let configPath = "Library/Application Support/Claude/claude_desktop_config.json"
    var config: URL { home.appendingPathComponent(Self.configPath) }

    public func isInstalled() -> Bool { fileExists(config) }

    public func collect() throws -> [CollectedFile] {
        guard fileExists(config) else { return [] }
        return [CollectedFile(kind: .mcpConfig, path: Self.configPath, modifiedAt: modificationDate(config), source: .file(config))]
    }

    public func summary() throws -> AgentSummary {
        let size = (try? FileManager.default.attributesOfItem(atPath: config.path)[.size] as? Int) ?? 0
        return AgentSummary(agentID: id, displayName: displayName, projectCount: 0, sessionCount: 0,
                            totalBytes: size, bytesByKind: fileExists(config) ? [.mcpConfig: size] : [:],
                            mcpServers: AgentCatalog.jsonMCP(config))
    }

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        for item in items where item.path == Self.configPath {
            let data = context.mapper.rewrite(try await context.load(item))
            plan.writes.append(try planSettingsMerge(data, target: config, policy: context.policy, notes: &plan.notes))
        }
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        plan.notes.append(.logInAfterRestore(agent: displayName, command: "open -a Claude"))
        return plan
    }
}
