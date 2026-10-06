import Foundation
import SQLite3
import Testing
@testable import AgentBackupCore

struct CodexProviderTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
    var oldHome: URL { root.appendingPathComponent("old/alice") }
    var newHome: URL { root.appendingPathComponent("new/bob") }
    let vault = Vault(rawKey: Data(repeating: 5, count: 32))

    func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in home: URL) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    var rollout: String { ".codex/sessions/2026/10/01/rollout-2026-10-01T09-00-00-abc.jsonl" }

    func seed() throws {
        let project = oldHome.path + "/Code/app"
        try write("""
        model = "gpt-5"
        [projects."\(project)"]
        trust_level = "trusted"
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "github-mcp"]
        """, ".codex/config.toml", in: oldHome)
        try write(#"{"session_id":"abc","ts":100,"text":"hello"}"# + "\n", ".codex/history.jsonl", in: oldHome)
        try write("""
        {"timestamp":"2026-10-01T09:00:00Z","type":"session_meta","payload":{"id":"abc","cwd":"\(project)","cli_version":"1.0"}}
        {"timestamp":"2026-10-01T09:00:01Z","type":"turn_context","payload":{"cwd":"\(project)"}}

        """, rollout, in: oldHome)
        try write("archived", ".codex/archived_sessions/rollout-2026-09-01T00-00-00-old.jsonl", in: oldHome)
        try write("Be terse.", ".codex/AGENTS.md", in: oldHome)
        try write("my skill", ".codex/skills/mine/SKILL.md", in: oldHome)
        try write("bundled", ".codex/skills/.system/builtin/SKILL.md", in: oldHome)
        try write(#"{"tokens":{"access_token":"secret"}}"#, ".codex/auth.json", in: oldHome)
        try write("log", ".codex/log/codex-tui.log", in: oldHome)
    }

    func makeIndex(in home: URL) throws -> URL {
        let db = home.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        sqlite3_open(db.path, &handle)
        sqlite3_exec(handle, """
            CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT NOT NULL, last_watermark TEXT, last_success_at INTEGER, updated_at INTEGER);
            INSERT INTO backfill_state VALUES (1, 'complete', 'sessions/2026/09/30/x.jsonl', 1, 1);
            """, nil, nil, nil)
        sqlite3_close(handle)
        return db
    }

    func backfillState(_ db: URL) -> (String, String?) {
        var handle: OpaquePointer?
        sqlite3_open(db.path, &handle)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT status, last_watermark FROM backfill_state", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
        let status = String(cString: sqlite3_column_text(statement, 0))
        let watermark = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        return (status, watermark)
    }

    func backupAndRestore(policy: ConflictPolicy = .keep) async throws -> [RestorePlan] {
        let engine = BackupEngine(store: LocalFolderStore(folder: root.appendingPathComponent("store")), vault: vault)
        let result = try await engine.backup(providers: [CodexProvider(home: oldHome)],
                                             source: SourceInfo(hostname: "old", userName: "alice", home: oldHome.path))
        let plans = try await engine.planRestore(manifest: result.manifest, targetHome: newHome, policy: policy)
        _ = try BackupEngine.apply(plans, home: newHome)
        return plans
    }

    @Test func collectsWhatTravelsAndNotLogins() throws {
        try seed()
        let files = try CodexProvider(home: oldHome).collect()
        let paths = Set(files.map(\.path))
        #expect(paths.contains(".codex/config.toml") && paths.contains(rollout) && paths.contains(".codex/skills/mine/SKILL.md"))
        #expect(!paths.contains(".codex/auth.json") && !paths.contains(".codex/skills/.system/builtin/SKILL.md"))
        #expect(!paths.contains { $0.contains("/log/") })
        #expect(files.first { $0.path == rollout }?.project?.path == oldHome.path + "/Code/app")
        #expect(files.filter { $0.kind == .session }.count == 2)

        let summary = try CodexProvider(home: oldHome).summary()
        #expect(summary.sessionCount == 2 && summary.projectCount == 1)
        #expect(summary.mcpServers.map(\.name) == ["github"])
    }

    @Test func restoresWithRewrittenPathsAndReindexes() async throws {
        try seed()
        let db = try makeIndex(in: newHome)
        let plans = try await backupAndRestore()

        let session = try #require(read(rollout, in: newHome))
        #expect(session.contains(newHome.path + "/Code/app") && !session.contains(oldHome.path))
        #expect(read(".codex/config.toml", in: newHome)?.contains("[projects.\"\(newHome.path)/Code/app\"]") == true)
        #expect(read(".codex/auth.json", in: newHome) == nil)

        #expect(plans[0].postActions == [.reindexCodexSessions(database: db)])
        let (status, watermark) = backfillState(db)
        #expect(status == "pending" && watermark == nil)
    }

    @Test func mergesHistoryByTs() async throws {
        try seed()
        try write(#"{"session_id":"new","ts":200,"text":"later"}"# + "\n", ".codex/history.jsonl", in: newHome)
        _ = try await backupAndRestore()
        let lines = read(".codex/history.jsonl", in: newHome)?.split(separator: "\n") ?? []
        #expect(lines.count == 2 && lines[0].contains("hello") && lines[1].contains("later"))
    }

    @Test func freshMacNeedsNoReindex() async throws {
        try seed()
        let plans = try await backupAndRestore()
        #expect(plans[0].postActions.isEmpty)   // no index yet: Codex indexes everything on first start
    }
}
