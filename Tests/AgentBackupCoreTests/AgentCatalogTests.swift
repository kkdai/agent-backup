import Foundation
import Testing
@testable import AgentBackupCore

struct AgentCatalogTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")

    func write(_ text: String, _ path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func detectsAgentsAndSizes() throws {
        try write(#"{"mcpServers":{"fs":{"command":"npx","args":["fs-mcp"]}}}"#, ".claude.json")
        try write(#"{"type":"user","cwd":"/p"}"# + "\n", ".claude/projects/-p/s.jsonl")
        try write(#"{"mcpServers":{"web":{"url":"https://example.com/mcp","headers":{"Authorization":"secret"}}}}"#, ".gemini/settings.json")

        let agents = AgentCatalog.scan(home: home)
        #expect(agents.prefix(2).map(\.id) == ["claude-code", "gemini-cli"]) // installed first

        let claude = try #require(agents.first { $0.id == "claude-code" })
        #expect(claude.support == .supported && claude.sessionCount == 1 && claude.projectCount == 1)
        #expect(claude.backupBytes == claude.bytesByKind.values.reduce(0, +))
        #expect(claude.bytesByKind[.session] != nil && claude.diskBytes > 0)
        #expect(claude.mcpServers.map(\.target) == ["npx fs-mcp"])

        let gemini = try #require(agents.first { $0.id == "gemini-cli" })
        #expect(gemini.support == .supported && gemini.backupBytes != nil)
        #expect(gemini.mcpServers.first?.transport == .http)
        #expect(gemini.mcpServers.first?.target == "https://example.com/mcp")

        #expect(agents.first { $0.id == "codex" }?.installed == false)
        #expect(agents.first { $0.id == "copilot-cli" }?.support == .planned(issue: 14))
    }

    @Test func readsCodexMCPServerNames() throws {
        try write("""
        model = "gpt-5"
        [mcp_servers.github]
        command = "npx"
        [mcp_servers.github.env]
        TOKEN = "secret"
        [mcp_servers."docs"]
        url = "https://docs.example.com/mcp"
        [profiles.fast]
        command = "not-a-server"
        """, ".codex/config.toml")
        let servers = AgentCatalog.codexMCP(home.appendingPathComponent(".codex/config.toml"))
        #expect(servers.map(\.name) == ["docs", "github"])
        #expect(servers.map(\.target) == ["https://docs.example.com/mcp", "npx"])
    }

    @Test func parsesSnapshotIDsWithoutDecrypting() throws {
        let date = Date(timeIntervalSince1970: 1_791_300_000)
        let id = BackupEngine.snapshotID(date: date, hostname: "Alice's MacBook Air")
        let parsed = try #require(BackupEngine.parseSnapshotID(id))
        #expect(parsed.date == date && parsed.hostname == "Alice s MacBook Air")
        #expect(BackupEngine.parseSnapshotID("garbage") == nil)
    }
}
