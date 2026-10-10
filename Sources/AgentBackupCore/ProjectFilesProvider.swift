import Foundation

/// Agent config that lives inside projects (`.mcp.json`, `CLAUDE.md`, `AGENTS.md`, …).
///
/// Only files git doesn't track are backed up: tracked ones already travel with the repository.
/// That still catches the files meant to stay local (`CLAUDE.local.md`, `.claude/settings.local.json`)
/// and config in projects that aren't git repositories. Restores never create project folders and
/// never replace a file the target repository tracks.
public struct ProjectFilesProvider: AgentProvider {
    public let id = "project-files"
    public let displayName = "專案設定檔"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    static let candidates = [
        ".mcp.json", "CLAUDE.md", "CLAUDE.local.md", ".claude/settings.local.json",
        "AGENTS.md", "GEMINI.md",
    ]

    public func isInstalled() -> Bool { !projectPaths().isEmpty }

    /// Every project an agent on this Mac knows about.
    func projectPaths() -> [String] {
        var paths = Set<String>()
        let claude = ClaudeCodeProvider(home: home)
        paths.formUnion(claude.projects().compactMap(\.path))
        paths.formUnion(((readJSONObject(claude.claudeJSON)?["projects"] as? [String: Any]) ?? [:]).keys)
        if let gemini = try? GeminiProvider(home: home).collect() { paths.formUnion(gemini.compactMap { $0.project?.path }) }
        if let codex = try? CodexProvider(home: home).collect() { paths.formUnion(codex.compactMap { $0.project?.path }) }
        return paths.filter { $0 != "/" && $0 != home.path && FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    public func collect() throws -> [CollectedFile] {
        var out: [CollectedFile] = []
        for project in projectPaths() {
            let dir = URL(fileURLWithPath: project, isDirectory: true)
            let present = Self.candidates.filter { fileExists(dir.appendingPathComponent($0)) }
            let tracked = Self.trackedFiles(present, in: dir)
            for name in present where !tracked.contains(name) {
                let url = dir.appendingPathComponent(name)
                out.append(CollectedFile(kind: Self.kind(name), path: name, project: ProjectRef(dirName: "", path: project),
                                         modifiedAt: modificationDate(url), source: .file(url)))
            }
        }
        return out
    }

    static func kind(_ name: String) -> ItemKind {
        name.hasSuffix(".mcp.json") ? .mcpConfig : name.hasSuffix(".json") ? .settings : .instructions
    }

    /// Which of `files` git tracks in `dir`. Not a repository (or no git) → none.
    static func trackedFiles(_ files: [String], in dir: URL) -> Set<String> {
        guard !files.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path, "ls-files", "--"] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    public func summary() throws -> AgentSummary {
        let files = try collect()
        var bytesByKind: [ItemKind: Int] = [:]
        for file in files {
            if case .file(let url) = file.source {
                bytesByKind[file.kind, default: 0] += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
        }
        return AgentSummary(agentID: id, displayName: displayName,
                            projectCount: Set(files.compactMap { $0.project?.path }).count, sessionCount: 0,
                            totalBytes: bytesByKind.values.reduce(0, +), bytesByKind: bytesByKind, mcpServers: [])
    }

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        var missing: [String: Int] = [:]
        for item in items {
            guard let original = item.project?.path else { continue }
            let project = URL(fileURLWithPath: context.mapper.map(path: original), isDirectory: true)
            guard fileExists(project) else {
                missing[project.path, default: 0] += 1
                continue
            }
            // The repository here has its own version: leave it to git.
            if Self.trackedFiles([item.path], in: project).contains(item.path) { continue }
            let data = context.mapper.rewrite(try await context.load(item))
            plan.writes.append(planFileWrite(target: project.appendingPathComponent(item.path), data: data, kind: item.kind,
                                             modifiedAt: item.modifiedAt, policy: context.policy))
        }
        for (project, count) in missing.sorted(by: { $0.key < $1.key }) {
            plan.notes.append(.projectMissing(path: project, files: count))
        }
        return plan
    }
}
