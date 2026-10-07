import Foundation

/// An MCP server in agent-neutral form: the basis for copying servers between agents.
public struct MCPServer: Equatable, Identifiable {
    public enum Transport: String, CaseIterable {
        case stdio, http, sse
    }

    public var name: String
    public var transport: Transport
    public var command: String?
    public var args: [String] = []
    public var env: [String: String] = [:]
    public var cwd: String?
    public var url: String?
    public var headers: [String: String] = [:]
    /// Claude Code project scope; nil for user scope.
    public var project: String?

    public var id: String { "\(project ?? "")\u{0}\(name)" }

    public init(name: String, transport: Transport, command: String? = nil, args: [String] = [], env: [String: String] = [:],
                cwd: String? = nil, url: String? = nil, headers: [String: String] = [:], project: String? = nil) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.url = url
        self.headers = headers
        self.project = project
    }

    /// Same server ignoring name and scope — used to show "same config" across agents.
    public func sameConfig(as other: MCPServer) -> Bool {
        var a = self, b = other
        a.name = ""; b.name = ""; a.project = nil; b.project = nil
        return a == b
    }

    /// Command line or URL, never env/header values.
    public var summary: String {
        transport == .stdio ? ([command ?? ""] + args).joined(separator: " ") : (url ?? "")
    }
}

public enum MCPWarning: Hashable {
    /// The target agent can't use this transport at all.
    case unsupportedTransport(agent: String, transport: MCPServer.Transport)
    /// A remote server was wrapped in `npx mcp-remote` because the target only runs local servers.
    case wrappedWithMcpRemote(server: String)
    /// A setting the target agent has no place for was dropped.
    case droppedField(server: String, field: String)
    case serverExists(server: String)

    public var message: String {
        switch self {
        case .unsupportedTransport(let agent, let transport): "\(agent) doesn't support \(transport.rawValue) MCP servers"
        case .wrappedWithMcpRemote(let server): "'\(server)' is remote; it will run through `npx mcp-remote`"
        case .droppedField(let server, let field): "'\(server)': \(field) isn't supported by the target and was left out"
        case .serverExists(let server): "'\(server)' already exists in the target and was kept"
        }
    }
}

/// Reads and writes the user-level MCP servers of each agent.
public struct MCPRegistry {
    public static let agentIDs = ["claude-code", "claude-desktop", "codex", "gemini-cli", "copilot-cli", "cursor"]

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    func configFile(_ agent: String) -> URL? {
        switch agent {
        case "claude-code": home.appendingPathComponent(".claude.json")
        case "claude-desktop": home.appendingPathComponent(ClaudeDesktopProvider.configPath)
        case "codex": home.appendingPathComponent(".codex/config.toml")
        case "gemini-cli": home.appendingPathComponent(".gemini/settings.json")
        case "copilot-cli": home.appendingPathComponent(".copilot/mcp-config.json")
        case "cursor": home.appendingPathComponent(".cursor/mcp.json")
        default: nil
        }
    }

    /// Whether the agent is set up on this Mac, so writing its config makes sense.
    public func isAvailable(_ agent: String) -> Bool {
        guard let file = configFile(agent) else { return false }
        return fileExists(file) || fileExists(file.deletingLastPathComponent())
            || (agent == "claude-desktop" && FileManager.default.fileExists(atPath: "/Applications/Claude.app"))
            || (agent == "cursor" && FileManager.default.fileExists(atPath: "/Applications/Cursor.app"))
    }

    // MARK: Reading

    public func servers(of agent: String) -> [MCPServer] {
        guard let file = configFile(agent) else { return [] }
        if agent == "codex" {
            return Self.parseCodex((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        }
        guard let root = readJSONObject(file) else { return [] }
        var out = Self.parseJSONServers(root["mcpServers"] as? [String: Any] ?? [:], agent: agent, project: nil)
        if agent == "claude-code" {
            for (path, entry) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let servers = (entry as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
                out += Self.parseJSONServers(servers, agent: agent, project: path)
            }
        }
        return out
    }

    static func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }
    static func stringMap(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    static func parseJSONServers(_ servers: [String: Any], agent: String, project: String?) -> [MCPServer] {
        servers.keys.sorted().compactMap { name in
            guard let c = servers[name] as? [String: Any] else { return nil }
            let type = (c["type"] as? String)?.lowercased()
            var server = MCPServer(name: name, transport: .stdio, command: c["command"] as? String, args: strings(c["args"]),
                                   env: stringMap(c["env"]), cwd: c["cwd"] as? String, headers: stringMap(c["headers"]), project: project)
            if let httpURL = c["httpUrl"] as? String {          // Gemini streamable HTTP
                server.transport = .http
                server.url = httpURL
            } else if let url = c["url"] as? String {
                server.url = url
                // Gemini's bare `url` means SSE; Claude/Copilot say so with `type`.
                server.transport = type == "sse" || (agent == "gemini-cli" && type == nil) ? .sse : .http
            } else if server.command == nil {
                return nil
            }
            return server
        }
    }

    static func parseCodex(_ text: String) -> [MCPServer] {
        var servers: [String: MCPServer] = [:]
        var order: [String] = []
        for entry in MiniTOML.entries(text) where entry.table.count >= 2 && entry.table[0] == "mcp_servers" {
            let name = entry.table[1]
            if servers[name] == nil {
                servers[name] = MCPServer(name: name, transport: .stdio)
                order.append(name)
            }
            if entry.table.count == 3 {   // [mcp_servers.x.env] / [mcp_servers.x.http_headers]
                if case .string(let value) = entry.value {
                    if entry.table[2] == "env" { servers[name]!.env[entry.key] = value }
                    if entry.table[2] == "http_headers" { servers[name]!.headers[entry.key] = value }
                }
                continue
            }
            switch (entry.key, entry.value) {
            case ("command", .string(let v)): servers[name]!.command = v
            case ("args", .array(let v)): servers[name]!.args = v
            case ("cwd", .string(let v)): servers[name]!.cwd = v
            case ("env", .table(let v)): servers[name]!.env.merge(v) { $1 }
            case ("http_headers", .table(let v)): servers[name]!.headers.merge(v) { $1 }
            case ("url", .string(let v)):
                servers[name]!.url = v
                servers[name]!.transport = .http
            default: break
            }
        }
        return order.compactMap { servers[$0] }.filter { $0.command != nil || $0.url != nil }
    }

    // MARK: Converting

    /// The server as the target agent's JSON object, or nil if it can't be expressed there.
    static func json(_ s: MCPServer, for agent: String, warnings: inout [MCPWarning]) -> [String: Any]? {
        var out: [String: Any] = [:]
        func local() {
            if let command = s.command { out["command"] = command }
            if !s.args.isEmpty { out["args"] = s.args }
            if !s.env.isEmpty { out["env"] = s.env }
        }
        switch (agent, s.transport) {
        case ("claude-code", .stdio):
            out["type"] = "stdio"
            local()
            if s.cwd != nil { warnings.append(.droppedField(server: s.name, field: "cwd")) }
        case ("claude-code", _):
            out["type"] = s.transport.rawValue
            out["url"] = s.url
            if !s.headers.isEmpty { out["headers"] = s.headers }
        case ("claude-desktop", .stdio):
            local()
            if s.cwd != nil { warnings.append(.droppedField(server: s.name, field: "cwd")) }
        case ("claude-desktop", _):
            // Desktop's config only launches local processes; bridge remote servers with mcp-remote.
            out["command"] = "npx"
            out["args"] = ["-y", "mcp-remote", s.url ?? ""] + s.headers.keys.sorted().flatMap { ["--header", "\($0): \(s.headers[$0]!)"] }
            warnings.append(.wrappedWithMcpRemote(server: s.name))
        case ("gemini-cli", .stdio):
            local()
            if let cwd = s.cwd { out["cwd"] = cwd }
        case ("gemini-cli", .http):
            out["httpUrl"] = s.url
            if !s.headers.isEmpty { out["headers"] = s.headers }
        case ("gemini-cli", .sse):
            out["url"] = s.url
            if !s.headers.isEmpty { out["headers"] = s.headers }
        case ("copilot-cli", .stdio):
            out["type"] = "local"
            local()
            out["tools"] = ["*"]
            if s.cwd != nil { warnings.append(.droppedField(server: s.name, field: "cwd")) }
        case ("cursor", .stdio):
            local()
            if s.cwd != nil { warnings.append(.droppedField(server: s.name, field: "cwd")) }
        case ("cursor", _):
            // Cursor detects streamable HTTP vs SSE from the URL itself.
            out["url"] = s.url
            if !s.headers.isEmpty { out["headers"] = s.headers }
            if s.transport == .sse { out["type"] = "sse" }
        case ("copilot-cli", _):
            out["type"] = s.transport.rawValue
            out["url"] = s.url
            if !s.headers.isEmpty { out["headers"] = s.headers }
            out["tools"] = ["*"]
        default:
            return nil
        }
        return out
    }

    static func codexTOML(_ s: MCPServer, warnings: inout [MCPWarning]) -> String? {
        var lines = ["[mcp_servers.\(MiniTOML.quoteKey(s.name))]"]
        switch s.transport {
        case .stdio:
            lines.append("command = \(MiniTOML.string(s.command ?? ""))")
            if !s.args.isEmpty { lines.append("args = \(MiniTOML.array(s.args))") }
            if let cwd = s.cwd { lines.append("cwd = \(MiniTOML.string(cwd))") }
            if !s.env.isEmpty { lines.append("env = \(MiniTOML.inlineTable(s.env))") }
        case .http:
            lines.append("url = \(MiniTOML.string(s.url ?? ""))")
            if !s.headers.isEmpty { lines.append("http_headers = \(MiniTOML.inlineTable(s.headers))") }
        case .sse:
            warnings.append(.unsupportedTransport(agent: "Codex CLI", transport: .sse))
            return nil
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Copying

    public struct CopyPlan {
        public var agent: String
        public var write: PlannedWrite?
        public var added: [String] = []
        public var replaced: [String] = []
        public var warnings: [MCPWarning] = []
    }

    /// Plans adding `servers` to the target agent's user-level config. Existing servers with the
    /// same name are kept unless `replace` is set. Nothing is written until the plan is applied.
    public func planCopy(_ servers: [MCPServer], to agent: String, replace: Bool = false) throws -> CopyPlan {
        guard let file = configFile(agent) else { throw BackupError.unsupportedFormat(0) }
        var plan = CopyPlan(agent: agent)
        let existing = Set(self.servers(of: agent).filter { $0.project == nil }.map(\.name))
        var accepted: [MCPServer] = []
        for server in servers {
            if existing.contains(server.name) && !replace {
                plan.warnings.append(.serverExists(server: server.name))
                continue
            }
            accepted.append(server)
        }

        let data: Data
        if agent == "codex" {
            let original = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var text = MiniTOML.removingTables(original, prefix: "mcp_servers", names: Set(accepted.map(\.name)))
            for server in accepted {
                guard let block = Self.codexTOML(server, warnings: &plan.warnings) else { continue }
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += (text.isEmpty ? "" : "\n") + block + "\n"
                (existing.contains(server.name) ? \CopyPlan.replaced : \CopyPlan.added).apply(server.name, to: &plan)
            }
            data = Data(text.utf8)
        } else {
            var root = readJSONObject(file) ?? [:]
            var current = root["mcpServers"] as? [String: Any] ?? [:]
            for server in accepted {
                guard let json = Self.json(server, for: agent, warnings: &plan.warnings) else {
                    plan.warnings.append(.unsupportedTransport(agent: agent, transport: server.transport))
                    continue
                }
                current[server.name] = json
                (existing.contains(server.name) ? \CopyPlan.replaced : \CopyPlan.added).apply(server.name, to: &plan)
            }
            root["mcpServers"] = current
            data = try serializeJSON(root)
        }

        if !plan.added.isEmpty || !plan.replaced.isEmpty {
            plan.write = planFileWrite(target: file, data: data, kind: .mcpConfig, modifiedAt: nil, policy: .replace)
        }
        return plan
    }
}

private extension WritableKeyPath where Root == MCPRegistry.CopyPlan, Value == [String] {
    func apply(_ name: String, to plan: inout MCPRegistry.CopyPlan) { plan[keyPath: self].append(name) }
}
