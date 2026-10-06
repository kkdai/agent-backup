import Foundation

/// Every coding agent the app knows about — including ones it can't back up yet, so the
/// UI can show what's on this Mac and what's coming.
public struct AgentInfo: Identifiable {
    public enum Support: Equatable {
        case supported
        /// Not backed up yet; `issue` is the GitHub issue tracking it.
        case planned(issue: Int)
    }

    public let id: String
    public let name: String
    public let support: Support
    public var installed: Bool
    /// Existing files/folders that belong to the agent.
    public var locations: [URL]
    /// Everything the agent keeps on disk, caches included.
    public var diskBytes: Int
    /// What a backup would contain (only for supported agents).
    public var backupBytes: Int?
    public var bytesByKind: [ItemKind: Int]
    public var sessionCount: Int?
    public var projectCount: Int?
    public var mcpServers: [MCPServerInfo]
    /// PIDs of this agent's processes running right now.
    public var runningPIDs: [Int32] = []

    public var isRunning: Bool { !runningPIDs.isEmpty }
}

public enum AgentCatalog {
    struct Definition {
        let id: String
        let name: String
        let support: AgentInfo.Support
        /// Relative to home.
        let paths: [String]
        /// Extra evidence the agent is installed even without data (e.g. an app bundle).
        let apps: [String]
        let mcp: (URL) -> [MCPServerInfo]
    }

    static let definitions: [Definition] = [
        Definition(id: "claude-code", name: "Claude Code", support: .supported,
                   paths: [".claude", ".claude.json"], apps: [], mcp: { _ in [] }),
        Definition(id: "codex", name: "Codex CLI", support: .supported,
                   paths: [".codex"], apps: [], mcp: { codexMCP($0.appendingPathComponent(".codex/config.toml")) }),
        Definition(id: "gemini-cli", name: "Gemini CLI", support: .supported,
                   paths: [".gemini"], apps: [], mcp: { jsonMCP($0.appendingPathComponent(".gemini/settings.json")) }),
        Definition(id: "copilot-cli", name: "GitHub Copilot CLI", support: .supported,
                   paths: [".copilot"], apps: [], mcp: { jsonMCP($0.appendingPathComponent(".copilot/mcp-config.json")) }),
        Definition(id: "claude-desktop", name: "Claude Desktop", support: .supported,
                   paths: ["Library/Application Support/Claude/claude_desktop_config.json"], apps: ["/Applications/Claude.app"],
                   mcp: { jsonMCP($0.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")) }),
        Definition(id: "cursor", name: "Cursor", support: .planned(issue: 18),
                   paths: [".cursor"], apps: ["/Applications/Cursor.app"], mcp: { jsonMCP($0.appendingPathComponent(".cursor/mcp.json")) }),
    ]

    /// Walks the disk; call off the main thread. Installed agents come first.
    public static func scan(home: URL) -> [AgentInfo] {
        let running = RunningAgents.find()
        return definitions.map { def -> AgentInfo in
            var info = scan(def, home: home)
            info.runningPIDs = running[def.id] ?? []
            return info
        }
            .enumerated()
            .sorted { ($0.element.installed ? 0 : 1, $0.offset) < ($1.element.installed ? 0 : 1, $1.offset) }
            .map(\.element)
    }

    static func scan(_ def: Definition, home: URL) -> AgentInfo {
        let locations = def.paths.map { home.appendingPathComponent($0) }.filter(fileExists)
        let installed = !locations.isEmpty || def.apps.contains { FileManager.default.fileExists(atPath: $0) }
        var info = AgentInfo(
            id: def.id, name: def.name, support: def.support, installed: installed, locations: locations,
            diskBytes: locations.reduce(0) { $0 + diskSize($1) }, backupBytes: nil, bytesByKind: [:],
            sessionCount: nil, projectCount: nil, mcpServers: def.mcp(home)
        )
        if let provider = Providers.provider(id: def.id, home: home), provider.isInstalled(),
           let summary = try? provider.summary() {
            info.backupBytes = summary.totalBytes
            info.bytesByKind = summary.bytesByKind
            info.sessionCount = summary.sessionCount
            info.projectCount = summary.projectCount
            info.mcpServers = summary.mcpServers
        }
        return info
    }

    /// Allocated size of a file or folder, without following symlinks.
    static func diskSize(_ url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true { return values.totalFileAllocatedSize ?? 0 }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            if let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += v.totalFileAllocatedSize ?? 0
            }
        }
        return total
    }

    static func jsonMCP(_ url: URL) -> [MCPServerInfo] {
        let servers = readJSONObject(url)?["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().map { MCPServerInfo(name: $0, project: nil, config: servers[$0] as? [String: Any] ?? [:]) }
    }

    /// Server names from `[mcp_servers.<name>]` tables; full TOML parsing comes with the Codex provider (#12).
    static func codexMCP(_ url: URL) -> [MCPServerInfo] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var servers: [String: [String: Any]] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                    let name = String(line.dropFirst("[mcp_servers.".count).dropLast())
                    if !name.contains(".") {
                        current = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        servers[current!] = [:]
                    }
                }
            } else if let current, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if key == "command" || key == "url" { servers[current]?[key] = value }
            }
        }
        return servers.keys.sorted().map { MCPServerInfo(name: $0, project: nil, config: servers[$0] ?? [:]) }
    }
}
