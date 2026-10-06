import Foundation
import Testing
@testable import AgentBackupCore

/// Backs up a fake `/…/old/alice` home and restores it into a fake `/…/new/al` home.
struct RoundTripTests {
    let root: URL
    let oldHome: URL
    let newHome: URL
    let storeDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-backup-tests-\(UUID().uuidString)")
        oldHome = root.appendingPathComponent("old/alice")
        newHome = root.appendingPathComponent("new/al")
        storeDir = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)
    }

    func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in home: URL) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    var oldProject: String { oldHome.path + "/Documents/my.app" }
    var oldDir: String { PathMapper.claudeProjectDirName(for: oldProject) }

    func seedOldHome() throws {
        try write("""
        {"oauthAccount":{"email":"secret@example.com"},"numStartups":3,
         "mcpServers":{"fs":{"command":"\(oldHome.path)/bin/fs-mcp","args":[]}},
         "projects":{"\(oldProject)":{"mcpServers":{"gh":{"type":"http","url":"https://example.com/mcp"}},"allowedTools":["Bash"],"lastCost":1.5}}}
        """, ".claude.json", in: oldHome)
        try write(#"{"model":"opus"}"#, ".claude/settings.json", in: oldHome)
        try write("""
        {"type":"user","cwd":"\(oldProject)","sessionId":"s1"}
        {"type":"assistant","cwd":"\(oldProject)","message":"edited \(oldProject)/main.swift"}

        """, ".claude/projects/\(oldDir)/s1.jsonl", in: oldHome)
        try write("remember this", ".claude/projects/\(oldDir)/memory/MEMORY.md", in: oldHome)
        try write(#"{"display":"old prompt","project":"\#(oldProject)","timestamp":100}"# + "\n", ".claude/history.jsonl", in: oldHome)
        try write("skill", ".claude/skills/mine/SKILL.md", in: oldHome)
        try write("managed", ".claude/skills/synced/x/SKILL.md", in: oldHome)
        try write("cache", ".claude/cache/junk", in: oldHome)
    }

    let vault = Vault(rawKey: Data(repeating: 7, count: 32))

    func backupAndPlan(policy: ConflictPolicy = .keep) async throws -> (BackupEngine, Manifest, [RestorePlan]) {
        let engine = BackupEngine(store: LocalFolderStore(folder: storeDir), vault: vault)
        let result = try await engine.backup(
            providers: Providers.all(home: oldHome),
            source: SourceInfo(hostname: "Old Mac", userName: "alice", home: oldHome.path)
        )
        let plans = try await engine.planRestore(manifest: result.manifest, targetHome: newHome, policy: policy)
        return (engine, result.manifest, plans)
    }

    @Test func backsUpOnlyWhatShouldTravel() async throws {
        try seedOldHome()
        let (_, manifest, _) = try await backupAndPlan()
        let items = try #require(manifest.agents.first?.items)
        let paths = Set(items.map(\.path))

        #expect(paths.contains(".claude/skills/mine/SKILL.md"))
        #expect(!paths.contains(".claude/skills/synced/x/SKILL.md"))
        #expect(!paths.contains { $0.contains("cache") })
        #expect(items.first { $0.kind == .session }?.project == ProjectRef(dirName: oldDir, path: oldProject))

        // The ~/.claude.json extract keeps MCP + allowed tools, never login or machine stats.
        let extract = try #require(items.first { $0.kind == .mcpConfig })
        let data = try vault.open(try await LocalFolderStore(folder: storeDir).blob(extract.blob), expectedID: extract.blob)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("oauthAccount") && !text.contains("lastCost") && !text.contains("numStartups"))
        #expect(text.contains("allowedTools"))
    }

    @Test func restoresIntoDifferentHomeWithRewrittenPaths() async throws {
        try seedOldHome()
        let (_, _, plans) = try await backupAndPlan()
        _ = try BackupEngine.apply(plans, home: newHome)

        let newProject = newHome.path + "/Documents/my.app"
        let newDir = PathMapper.claudeProjectDirName(for: newProject)
        let session = try read(".claude/projects/\(newDir)/s1.jsonl", in: newHome)
        #expect(session.contains(#""cwd":"\#(newProject)""#))
        #expect(session.contains("edited \(newProject)/main.swift"))
        #expect(!session.contains(oldHome.path))
        #expect(try read(".claude/projects/\(newDir)/memory/MEMORY.md", in: newHome) == "remember this")

        let claudeJSON = try #require(readJSONObject(newHome.appendingPathComponent(".claude.json")))
        #expect(claudeJSON["oauthAccount"] == nil)
        let fs = (claudeJSON["mcpServers"] as? [String: Any])?["fs"] as? [String: Any]
        #expect(fs?["command"] as? String == newHome.path + "/bin/fs-mcp")
        let project = (claudeJSON["projects"] as? [String: Any])?[newProject] as? [String: Any]
        #expect((project?["mcpServers"] as? [String: Any])?["gh"] != nil)
        #expect(project?["allowedTools"] as? [String] == ["Bash"])

        #expect(try read(".claude/history.jsonl", in: newHome).contains(newProject))
    }

    @Test func mergesWithExistingDataOnTarget() async throws {
        try seedOldHome()
        try write("""
        {"oauthAccount":{"email":"new@example.com"},"mcpServers":{"fs":{"command":"local-fs"},"local":{"command":"x"}}}
        """, ".claude.json", in: newHome)
        try write(#"{"model":"sonnet"}"#, ".claude/settings.json", in: newHome)
        try write(#"{"display":"new prompt","project":"/p","timestamp":200}"# + "\n", ".claude/history.jsonl", in: newHome)

        let (_, _, plans) = try await backupAndPlan(policy: .keep)
        let result = try BackupEngine.apply(plans, home: newHome)

        let claudeJSON = try #require(readJSONObject(newHome.appendingPathComponent(".claude.json")))
        #expect((claudeJSON["oauthAccount"] as? [String: Any])?["email"] as? String == "new@example.com")
        let servers = try #require(claudeJSON["mcpServers"] as? [String: Any])
        #expect((servers["fs"] as? [String: Any])?["command"] as? String == "local-fs")
        #expect(servers["local"] != nil)
        #expect(plans[0].notes.contains { $0.contains("'fs'") })

        #expect(try read(".claude/settings.json", in: newHome) == #"{"model":"sonnet"}"#)
        let history = try read(".claude/history.jsonl", in: newHome).split(separator: "\n")
        #expect(history.count == 2 && history[0].contains("old prompt") && history[1].contains("new prompt"))

        // The overwritten ~/.claude.json was saved for rollback.
        let rollback = try #require(result.rollbackDir)
        #expect(FileManager.default.fileExists(atPath: rollback.appendingPathComponent("files/.claude.json").path))
    }

    @Test func renamePolicyKeepsBoth() async throws {
        try seedOldHome()
        try write(#"{"mcpServers":{"fs":{"command":"local-fs"}}}"#, ".claude.json", in: newHome)
        try write(#"{"model":"sonnet"}"#, ".claude/settings.json", in: newHome)

        let (_, _, plans) = try await backupAndPlan(policy: .rename)
        _ = try BackupEngine.apply(plans, home: newHome)

        let servers = try #require(readJSONObject(newHome.appendingPathComponent(".claude.json"))?["mcpServers"] as? [String: Any])
        #expect(servers["fs"] != nil && servers["fs-restored"] != nil)
        #expect(try read(".claude/settings.restored.json", in: newHome) == #"{"model":"opus"}"#)
    }

    @Test func sessionsAppendedOnTargetAreNotClobbered() async throws {
        try seedOldHome()
        let (engine, manifest, _) = try await backupAndPlan()
        _ = try BackupEngine.apply(try await engine.planRestore(manifest: manifest, targetHome: newHome), home: newHome)

        let newDir = PathMapper.claudeProjectDirName(for: newHome.path + "/Documents/my.app")
        let path = ".claude/projects/\(newDir)/s1.jsonl"
        try write(try read(path, in: newHome) + #"{"type":"user","message":"continued on new Mac"}"# + "\n", path, in: newHome)

        let again = try await engine.planRestore(manifest: manifest, targetHome: newHome)
        #expect(again[0].writes.allSatisfy { !$0.writes })
    }

    @Test func nothingIsStoredInPlaintext() async throws {
        try seedOldHome()
        _ = try await backupAndPlan()
        let store = storeDir.appendingPathComponent("AgentBackup")
        for file in FileManager.default.enumerator(atPath: store.path)!.compactMap({ $0 as? String }) where !file.hasSuffix("keyfile.json") {
            guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(file).path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("alice") && !text.contains("mcpServers") && !text.contains("remember this"), "\(file)")
        }
    }

    @Test func secondBackupUploadsNothingNew() async throws {
        try seedOldHome()
        let engine = BackupEngine(store: LocalFolderStore(folder: storeDir), vault: vault)
        let source = SourceInfo(hostname: "Old Mac", userName: "alice", home: oldHome.path)
        _ = try await engine.backup(providers: Providers.all(home: oldHome), source: source, now: Date(timeIntervalSince1970: 0))
        let second = try await engine.backup(providers: Providers.all(home: oldHome), source: source, now: Date(timeIntervalSince1970: 60))
        #expect(second.newBlobCount == 0)
        #expect(try await engine.manifests().count == 2)
        #expect(try await engine.manifest(id: nil).createdAt == Date(timeIntervalSince1970: 60))
    }
}
