import Foundation
import Testing
@testable import AgentBackupCore

struct CopilotProviderTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString)")
    var oldHome: URL { root.appendingPathComponent("old/alice") }
    var newHome: URL { root.appendingPathComponent("new/bob") }

    func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in home: URL) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    func seed() throws {
        try write(#"{"mcpServers":{"fs":{"command":"\#(oldHome.path)/bin/fs"}}}"#, ".copilot/mcp-config.json", in: oldHome)
        try write(#"{"model":"gpt-5"}"#, ".copilot/settings.json", in: oldHome)
        try write("Prefer Swift.", ".copilot/copilot-instructions.md", in: oldHome)
        try write("agent", ".copilot/agents/reviewer.agent.md", in: oldHome)
        try write(#"{"type":"session.start","cwd":"\#(oldHome.path)/app"}"# + "\n", ".copilot/session-state/s1/events.jsonl", in: oldHome)
        try write("plan", ".copilot/session-state/s1/plan.md", in: oldHome)
        try write("// managed\n{\"loggedInUsers\":[{\"token\":\"secret\"}]}", ".copilot/config.json", in: oldHome)
        try write("{}", ".copilot/permissions-config.json", in: oldHome)
        try write("tok", ".copilot/mcp-oauth-config/github.json", in: oldHome)
        try write("db", ".copilot/session-store.db", in: oldHome)
        try write("log", ".copilot/logs/process-1.log", in: oldHome)
    }

    @Test func collectsPortableFilesOnly() throws {
        try seed()
        let paths = Set(try CopilotProvider(home: oldHome).collect().map(\.path))
        #expect(paths.isSuperset(of: [".copilot/mcp-config.json", ".copilot/settings.json", ".copilot/agents/reviewer.agent.md",
                                      ".copilot/session-state/s1/events.jsonl"]))
        for secret in ["config.json", "permissions-config.json", "mcp-oauth-config/github.json", "session-store.db", "logs/process-1.log"] {
            #expect(!paths.contains(".copilot/\(secret)"))
        }
        let summary = try CopilotProvider(home: oldHome).summary()
        #expect(summary.sessionCount == 1 && summary.mcpServers.map(\.name) == ["fs"])
    }

    @Test func restoresMergingMCPAndNeverOverwritingSessions() async throws {
        try seed()
        try write(#"{"mcpServers":{"local":{"command":"x"}}}"#, ".copilot/mcp-config.json", in: newHome)
        try write("mine", ".copilot/session-state/s1/plan.md", in: newHome)

        let engine = BackupEngine(store: LocalFolderStore(folder: root.appendingPathComponent("store")),
                                  vault: Vault(rawKey: Data(repeating: 7, count: 32)))
        let result = try await engine.backup(providers: [CopilotProvider(home: oldHome)],
                                             source: SourceInfo(hostname: "old", userName: "alice", home: oldHome.path))
        let plans = try await engine.planRestore(manifest: result.manifest, targetHome: newHome, policy: .replace)
        _ = try BackupEngine.apply(plans, home: newHome)

        let mcp = try #require(read(".copilot/mcp-config.json", in: newHome))
        #expect(mcp.contains("\"local\"") && mcp.contains(newHome.path + "/bin/fs"))
        #expect(read(".copilot/session-state/s1/plan.md", in: newHome) == "mine")   // even with policy .replace
        #expect(read(".copilot/session-state/s1/events.jsonl", in: newHome)?.contains(newHome.path + "/app") == true)
        #expect(read(".copilot/config.json", in: newHome) == nil)
        #expect(plans[0].notes.contains(.sessionsMayNotBeListed(agent: "GitHub Copilot CLI")))
    }
}
