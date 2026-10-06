import Foundation
import Testing
@testable import AgentBackupCore

struct ClaudeDesktopProviderTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)")
    var oldHome: URL { root.appendingPathComponent("old/alice") }
    var newHome: URL { root.appendingPathComponent("new/bob") }

    func write(_ text: String, in home: URL) throws {
        let url = home.appendingPathComponent(ClaudeDesktopProvider.configPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func mergesMCPServersIntoExistingConfig() async throws {
        try write(#"{"mcpServers":{"fs":{"command":"npx","args":["fs","\#(oldHome.path)/notes"]}},"preferences":{"menuBar":true}}"#, in: oldHome)
        try write(#"{"mcpServers":{"local":{"command":"x"}},"preferences":{"menuBar":false}}"#, in: newHome)

        let provider = ClaudeDesktopProvider(home: oldHome)
        #expect(provider.isInstalled())
        #expect(try provider.summary().mcpServers.map(\.name) == ["fs"])

        let engine = BackupEngine(store: LocalFolderStore(folder: root.appendingPathComponent("store")),
                                  vault: Vault(rawKey: Data(repeating: 8, count: 32)))
        let result = try await engine.backup(providers: [provider],
                                             source: SourceInfo(hostname: "old", userName: "alice", home: oldHome.path))
        _ = try BackupEngine.apply(try await engine.planRestore(manifest: result.manifest, targetHome: newHome), home: newHome)

        let config = try #require(readJSONObject(newHome.appendingPathComponent(ClaudeDesktopProvider.configPath)))
        let servers = try #require(config["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["fs", "local"])
        #expect(((servers["fs"] as? [String: Any])?["args"] as? [String])?.last == newHome.path + "/notes")
        #expect((config["preferences"] as? [String: Bool]) == ["menuBar": false])   // this Mac's preference kept
    }

    @Test func notInstalledWithoutConfig() {
        #expect(!ClaudeDesktopProvider(home: oldHome).isInstalled())
    }
}
