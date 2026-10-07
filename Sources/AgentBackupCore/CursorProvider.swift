import Foundation

/// Cursor (`~/.cursor/mcp.json`).
///
/// Only the global MCP config travels. Cursor keeps chats in VS Code-style
/// `workspaceStorage/<id>/state.vscdb` databases whose `<id>` is derived from the workspace
/// folder (including its creation time on macOS), so copied chats wouldn't attach to the same
/// project on another Mac; they're left to Cursor's own account sync.
public struct CursorProvider: AgentProvider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    static let configPath = ".cursor/mcp.json"
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
                            mcpServers: MCPRegistry(home: home).servers(of: id).map(MCPServerInfo.init))
    }

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        for item in items where item.path == Self.configPath {
            let data = context.mapper.rewrite(try await context.load(item))
            plan.writes.append(try planSettingsMerge(data, target: config, policy: context.policy, notes: &plan.notes))
        }
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        return plan
    }
}
