import Foundation
import Testing
@testable import AgentBackupCore

struct GeminiProviderTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-\(UUID().uuidString)")
    var oldHome: URL { root.appendingPathComponent("old/alice") }
    var newHome: URL { root.appendingPathComponent("new/bob") }

    var oldProject: String { oldHome.path + "/Documents/rbtree" }
    var newProject: String { newHome.path + "/Code/rbtree" }

    func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in home: URL) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    func json(_ path: String, in home: URL) -> Any? {
        (try? Data(contentsOf: home.appendingPathComponent(path))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    func seed() throws {
        let hash = GeminiProvider.projectHash(oldProject)
        try write(#"{"mcpServers":{"web":{"httpUrl":"https://example.com/mcp"}},"ui":{"theme":"dark"}}"#, ".gemini/settings.json", in: oldHome)
        try write(#"{"projects":{"\#(oldProject)":"rbtree"}}"#, ".gemini/projects.json", in: oldHome)
        try write(#"{"\#(oldProject)":"TRUST_FOLDER"}"#, ".gemini/trustedFolders.json", in: oldHome)
        try write("Be kind.", ".gemini/GEMINI.md", in: oldHome)
        try write(oldProject, ".gemini/tmp/rbtree/.project_root", in: oldHome)
        try write("""
        {"sessionId":"s1","projectHash":"\(hash)","startTime":"2026-10-01T00:00:00Z","lastUpdated":"2026-10-01T00:01:00Z","kind":"main"}
        {"id":"m1","timestamp":"2026-10-01T00:00:10Z","type":"user","content":"look at \(oldProject)/tree.go"}

        """, ".gemini/tmp/rbtree/chats/session-2026-10-01T00-00-s1.jsonl", in: oldHome)
        try write(#"[{"sessionId":"s1","messageId":0,"type":"user","message":"old","timestamp":"2026-10-01T00:00:10Z"}]"#,
                  ".gemini/tmp/rbtree/logs.json", in: oldHome)
        try write("binary", ".gemini/tmp/bin/rg", in: oldHome)
        try write(#"{"access_token":"secret"}"#, ".gemini/oauth_creds.json", in: oldHome)
        try write("checkpoint", ".gemini/history/rbtree/.gitconfig", in: oldHome)
        try write("other product", ".gemini/antigravity-cli/history.jsonl", in: oldHome)
    }

    func restore(policy: ConflictPolicy = .keep, rules: [PathMapper.Rule] = []) async throws -> [RestorePlan] {
        let engine = BackupEngine(store: LocalFolderStore(folder: root.appendingPathComponent("store")),
                                  vault: Vault(rawKey: Data(repeating: 6, count: 32)))
        let result = try await engine.backup(providers: [GeminiProvider(home: oldHome)],
                                             source: SourceInfo(hostname: "old", userName: "alice", home: oldHome.path))
        let plans = try await engine.planRestore(manifest: result.manifest, targetHome: newHome, extraRules: rules, policy: policy)
        _ = try BackupEngine.apply(plans, home: newHome)
        return plans
    }

    @Test func collectsProjectsButNotLoginsOrCheckpoints() throws {
        try seed()
        let files = try GeminiProvider(home: oldHome).collect()
        let paths = Set(files.map(\.path))
        #expect(paths.contains(".gemini/settings.json") && paths.contains(".gemini/tmp/rbtree/logs.json"))
        #expect(!paths.contains { $0.contains("oauth") || $0.contains("/history/") || $0.contains("/bin/") || $0.contains("antigravity") })
        #expect(files.first { $0.kind == .session }?.project == ProjectRef(dirName: "rbtree", path: oldProject))

        let summary = try GeminiProvider(home: oldHome).summary()
        #expect(summary.sessionCount == 1 && summary.projectCount == 1 && summary.mcpServers.map(\.name) == ["web"])
    }

    @Test func movedProjectGetsNewPathAndHash() async throws {
        try seed()
        _ = try await restore(rules: [.init(from: oldProject, to: newProject)])

        let session = try #require(read(".gemini/tmp/rbtree/chats/session-2026-10-01T00-00-s1.jsonl", in: newHome))
        #expect(session.contains(GeminiProvider.projectHash(newProject)))
        #expect(!session.contains(GeminiProvider.projectHash(oldProject)))
        #expect(session.contains("\(newProject)/tree.go"))
        #expect(read(".gemini/tmp/rbtree/.project_root", in: newHome) == newProject)
        #expect(((json(".gemini/projects.json", in: newHome) as? [String: Any])?["projects"] as? [String: String]) == [newProject: "rbtree"])
        #expect((json(".gemini/trustedFolders.json", in: newHome) as? [String: String]) == [newProject: "TRUST_FOLDER"])
        #expect(read(".gemini/oauth_creds.json", in: newHome) == nil)
    }

    @Test func mergesIntoExistingSetup() async throws {
        try seed()
        try write(#"{"mcpServers":{"web":{"httpUrl":"https://local"},"mine":{"command":"x"}},"ui":{"theme":"light"}}"#,
                  ".gemini/settings.json", in: newHome)
        try write(#"{"projects":{"/elsewhere":"elsewhere"}}"#, ".gemini/projects.json", in: newHome)
        try write(#"[{"sessionId":"s9","messageId":0,"type":"user","message":"new","timestamp":"2026-10-02T00:00:00Z"}]"#,
                  ".gemini/tmp/rbtree/logs.json", in: newHome)

        let plans = try await restore()
        let settings = try #require(json(".gemini/settings.json", in: newHome) as? [String: Any])
        #expect((settings["ui"] as? [String: String]) == ["theme": "light"])   // local preference kept
        let servers = try #require(settings["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["web", "mine"])
        #expect((servers["web"] as? [String: String]) == ["httpUrl": "https://local"])
        #expect(plans[0].notes.contains(.mcpConflictKept(server: "web", scope: nil)))

        let projects = (json(".gemini/projects.json", in: newHome) as? [String: Any])?["projects"] as? [String: String]
        #expect(projects?.count == 2)
        let logs = try #require(json(".gemini/tmp/rbtree/logs.json", in: newHome) as? [[String: Any]])
        #expect(logs.map { $0["message"] as? String } == ["old", "new"])
    }
}
