import Foundation
import Testing
@testable import AgentBackupCore

struct ProjectFilesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("projfiles-\(UUID().uuidString)")
    var oldHome: URL { root.appendingPathComponent("old/alice") }
    var newHome: URL { root.appendingPathComponent("new/bob") }

    func write(_ text: String, _ path: String, in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
    }

    /// `repo` is a git repo with CLAUDE.md committed; `plain` isn't a repo.
    func seed() throws -> (repo: URL, plain: URL) {
        let repo = oldHome.appendingPathComponent("Code/repo")
        let plain = oldHome.appendingPathComponent("Code/plain")
        try write("shared rules", "CLAUDE.md", in: repo)
        try write("my notes \(repo.path)", "CLAUDE.local.md", in: repo)
        try write(#"{"permissions":{}}"#, ".claude/settings.local.json", in: repo)
        try git(["init", "-q"], in: repo)
        try git(["add", "CLAUDE.md"], in: repo)
        try git(["commit", "-qm", "init"], in: repo)
        try write(#"{"mcpServers":{}}"#, ".mcp.json", in: plain)
        try write("agents", "AGENTS.md", in: plain)
        try write(#"{"projects":{"\#(repo.path)":{},"\#(plain.path)":{}}}"#, ".claude.json", in: oldHome)
        return (repo, plain)
    }

    @Test func backsUpOnlyUntrackedFiles() throws {
        let (repo, plain) = try seed()
        let files = try ProjectFilesProvider(home: oldHome).collect()
        let byProject = Dictionary(grouping: files) { $0.project?.path ?? "" }.mapValues { Set($0.map(\.path)) }
        #expect(byProject[repo.path] == ["CLAUDE.local.md", ".claude/settings.local.json"])   // CLAUDE.md is in git
        #expect(byProject[plain.path] == [".mcp.json", "AGENTS.md"])
    }

    @Test func restoresIntoExistingProjectsOnly() async throws {
        let (_, _) = try seed()
        // New Mac: repo cloned (CLAUDE.md tracked, differs), plain project missing.
        let newRepo = newHome.appendingPathComponent("Code/repo")
        try write("repo version", "CLAUDE.md", in: newRepo)
        try git(["init", "-q"], in: newRepo)
        try git(["add", "CLAUDE.md"], in: newRepo)
        try git(["commit", "-qm", "init"], in: newRepo)

        let engine = BackupEngine(store: LocalFolderStore(folder: root.appendingPathComponent("store")),
                                  vault: Vault(rawKey: Data(repeating: 4, count: 32)))
        let result = try await engine.backup(providers: [ProjectFilesProvider(home: oldHome)],
                                             source: SourceInfo(hostname: "old", userName: "alice", home: oldHome.path))
        let plans = try await engine.planRestore(manifest: result.manifest, targetHome: newHome, policy: .replace)
        _ = try BackupEngine.apply(plans, home: newHome)

        #expect(try String(contentsOf: newRepo.appendingPathComponent("CLAUDE.local.md"), encoding: .utf8) == "my notes \(newRepo.path)")
        #expect(FileManager.default.fileExists(atPath: newRepo.appendingPathComponent(".claude/settings.local.json").path))
        #expect(try String(contentsOf: newRepo.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "repo version")
        #expect(!FileManager.default.fileExists(atPath: newHome.appendingPathComponent("Code/plain").path))   // not created
        #expect(plans[0].notes.contains(.projectMissing(path: newHome.path + "/Code/plain", files: 2)))
    }
}
