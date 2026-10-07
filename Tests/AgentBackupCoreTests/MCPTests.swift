import Foundation
import Testing
@testable import AgentBackupCore

struct MiniTOMLTests {
    @Test func parsesCodexServerTables() {
        let servers = MCPRegistry.parseCodex("""
        model = "gpt-5" # comment
        [mcp_servers.github]
        command = "npx"
        args = [
          "-y",   # trailing comment
          "github-mcp",
        ]
        env = { "GITHUB_TOKEN" = "t0k", PLAIN = 'lit' }
        [mcp_servers.github.env]
        EXTRA = "e"
        [mcp_servers."my docs"]
        url = "https://docs.example.com/mcp"
        http_headers = { Authorization = "Bearer x" }
        [profiles.fast]
        command = "not-a-server"
        """)
        #expect(servers.map(\.name) == ["github", "my docs"])
        #expect(servers[0] == MCPServer(name: "github", transport: .stdio, command: "npx", args: ["-y", "github-mcp"],
                                        env: ["GITHUB_TOKEN": "t0k", "PLAIN": "lit", "EXTRA": "e"]))
        #expect(servers[1].transport == .http && servers[1].headers == ["Authorization": "Bearer x"])
    }

    @Test func escapesAndRoundTrips() {
        var warnings: [MCPWarning] = []
        let server = MCPServer(name: "we.ird name", transport: .stdio, command: "/bin/say \"hi\"", args: ["a\\b", "line\nbreak", "中文"],
                               env: ["K": "v\t1"], cwd: "/tmp")
        let toml = MCPRegistry.codexTOML(server, warnings: &warnings)!
        #expect(MCPRegistry.parseCodex(toml) == [server])
    }

    @Test func removesOnlyTheNamedTables() {
        let text = """
        model = "x"
        [mcp_servers.a]
        command = "a"
        [mcp_servers.a.env]
        K = "v"
        [mcp_servers.b]
        command = "b"
        [profiles.p]
        model = "y"
        """
        let result = MiniTOML.removingTables(text, prefix: "mcp_servers", names: ["a"])
        #expect(MCPRegistry.parseCodex(result).map(\.name) == ["b"])
        #expect(result.contains("[profiles.p]") && result.contains("model = \"x\""))
    }
}

struct MCPCopyTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
    var registry: MCPRegistry { MCPRegistry(home: home) }

    func write(_ text: String, _ path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    let local = MCPServer(name: "fs", transport: .stdio, command: "npx", args: ["-y", "fs-mcp"], env: ["ROOT": "/data"])
    let remote = MCPServer(name: "docs", transport: .http, url: "https://docs.example.com/mcp", headers: ["Authorization": "Bearer t"])
    let legacy = MCPServer(name: "old", transport: .sse, url: "https://old.example.com/sse")

    func copy(_ servers: [MCPServer], to agent: String, replace: Bool = false) throws -> MCPRegistry.CopyPlan {
        let plan = try registry.planCopy(servers, to: agent, replace: replace)
        var restore = RestorePlan(agentID: agent)
        restore.writes = plan.write.map { [$0] } ?? []
        _ = try BackupEngine.apply([restore], home: home)
        return plan
    }

    @Test func readsEveryJSONFlavour() throws {
        try write(#"{"mcpServers":{"a":{"type":"http","url":"https://a"}},"projects":{"/p":{"mcpServers":{"b":{"command":"b"}}}}}"#, ".claude.json")
        try write(#"{"mcpServers":{"h":{"httpUrl":"https://h"},"s":{"url":"https://s"},"l":{"command":"l","cwd":"/w"}}}"#, ".gemini/settings.json")
        try write(#"{"mcpServers":{"c":{"type":"local","command":"c","tools":["*"]},"r":{"type":"sse","url":"https://r"}}}"#, ".copilot/mcp-config.json")

        let claude = registry.servers(of: "claude-code")
        #expect(claude.map(\.name) == ["a", "b"] && claude[1].project == "/p" && claude[0].transport == .http)
        let gemini = Dictionary(uniqueKeysWithValues: registry.servers(of: "gemini-cli").map { ($0.name, $0) })
        #expect(gemini["h"]?.transport == .http && gemini["s"]?.transport == .sse && gemini["l"]?.cwd == "/w")
        let copilot = Dictionary(uniqueKeysWithValues: registry.servers(of: "copilot-cli").map { ($0.name, $0) })
        #expect(copilot["c"]?.transport == .stdio && copilot["r"]?.transport == .sse)
    }

    @Test func copiesIntoEachAgentFaithfully() throws {
        try write(#"{"numStartups":3}"#, ".claude.json")
        try write("model = \"gpt-5\"\n", ".codex/config.toml")
        try write(#"{"ui":{"theme":"dark"}}"#, ".gemini/settings.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)

        for agent in ["claude-code", "gemini-cli", "copilot-cli"] {
            let plan = try copy([local, remote, legacy], to: agent)
            #expect(plan.added.sorted() == ["docs", "fs", "old"], "\(agent)")
            let back = Dictionary(uniqueKeysWithValues: registry.servers(of: agent).map { ($0.name, $0) })
            #expect(back["fs"]?.sameConfig(as: local) == true, "\(agent)")
            #expect(back["docs"]?.sameConfig(as: remote) == true, "\(agent)")
            #expect(back["old"]?.sameConfig(as: legacy) == true, "\(agent)")
        }
        #expect(readJSONObject(home.appendingPathComponent(".claude.json"))?["numStartups"] as? Int == 3)   // rest of the file kept
        #expect(((readJSONObject(home.appendingPathComponent(".gemini/settings.json"))?["ui"]) as? [String: String]) == ["theme": "dark"])

        let codex = try copy([local, remote, legacy], to: "codex")
        #expect(codex.added.sorted() == ["docs", "fs"])
        #expect(codex.warnings.contains(.unsupportedTransport(agent: "Codex CLI", transport: .sse)))
        let codexBack = Dictionary(uniqueKeysWithValues: registry.servers(of: "codex").map { ($0.name, $0) })
        #expect(codexBack["fs"]?.sameConfig(as: local) == true && codexBack["docs"]?.sameConfig(as: remote) == true)
        #expect((try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)).hasPrefix("model = \"gpt-5\""))
    }

    @Test func claudeDesktopBridgesRemoteServers() throws {
        try write("{}", ClaudeDesktopProvider.configPath)
        let plan = try copy([remote], to: "claude-desktop")
        #expect(plan.warnings == [.wrappedWithMcpRemote(server: "docs")])
        let server = try #require(registry.servers(of: "claude-desktop").first)
        #expect(server.command == "npx" && server.args == ["-y", "mcp-remote", "https://docs.example.com/mcp", "--header", "Authorization: Bearer t"])
    }

    @Test func keepsExistingUnlessReplacing() throws {
        try write(#"{"mcpServers":{"fs":{"command":"mine"}}}"#, ".gemini/settings.json")
        let kept = try copy([local], to: "gemini-cli")
        #expect(kept.write == nil && kept.warnings == [.serverExists(server: "fs")])
        #expect(registry.servers(of: "gemini-cli").first?.command == "mine")

        let replaced = try copy([local], to: "gemini-cli", replace: true)
        #expect(replaced.replaced == ["fs"])
        #expect(registry.servers(of: "gemini-cli").first?.sameConfig(as: local) == true)

        // Every copy leaves a rollback point.
        #expect(RollbackPoint.list(home: home).count == 1)
    }
}
