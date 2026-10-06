import AgentBackupCore
import ArgumentParser
import Foundation

@main
struct AgentBackupCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-backup",
        abstract: "Back up coding-agent MCP configs and sessions, and restore them on another Mac.",
        subcommands: [Detect.self, Backup.self, Snapshots.self, Restore.self]
    )
}

struct HomeOption: ParsableArguments {
    @Option(help: "Home directory to read from / restore into (defaults to yours; use a temp folder to try things safely).")
    var home: String?

    var url: URL {
        URL(fileURLWithPath: (home.map { NSString(string: $0).expandingTildeInPath }) ?? NSHomeDirectory(), isDirectory: true)
    }
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which agents are installed and what would be backed up.")
    @OptionGroup var home: HomeOption

    func run() throws {
        for provider in Providers.all(home: home.url) {
            guard provider.isInstalled() else {
                print("\(provider.displayName): not installed")
                continue
            }
            let s = try provider.summary()
            print("\(s.displayName): \(s.sessionCount) sessions in \(s.projectCount) projects, \(formatBytes(s.totalBytes))")
            for server in s.mcpServers {
                print("  MCP \(server.name) [\(server.transport.rawValue)] \(server.project ?? "(user)") → \(server.target)")
            }
        }
    }
}

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a snapshot in a backup folder.")
    @Option(name: .customLong("to"), help: "Folder that holds (or will hold) the AgentBackup/ directory.")
    var destination: String
    @OptionGroup var home: HomeOption

    func run() async throws {
        let homeURL = home.url
        let source = SourceInfo(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            userName: homeURL.lastPathComponent, home: homeURL.path
        )
        let engine = BackupEngine(store: LocalFolderStore(folder: expand(destination)))
        let result = try await engine.backup(providers: Providers.all(home: homeURL), source: source)
        print("Snapshot \(result.manifest.id)")
        for agent in result.manifest.agents {
            let counts = Dictionary(grouping: agent.items, by: \.kind)
            let parts = ItemKind.allCases.compactMap { kind in counts[kind].map { "\($0.count) \(kind.label.lowercased())" } }
            print("  \(agent.agentID): \(parts.joined(separator: ", "))")
        }
        print("\(result.fileCount) files (\(formatBytes(result.manifest.totalSize))); stored \(result.newBlobCount) new blobs (\(formatBytes(result.uploadedBytes))).")
        print("Note: M0 stores blobs compressed but NOT encrypted — MCP API keys are readable in this folder.")
    }
}

struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List snapshots in a backup folder.")
    @Option(name: .customLong("from"), help: "Folder that holds the AgentBackup/ directory.")
    var source: String

    func run() async throws {
        let manifests = try await LocalFolderStore(folder: expand(source)).manifests()
        if manifests.isEmpty { print("No snapshots.") }
        for m in manifests {
            let agents = m.agents.map { "\($0.agentID) (\($0.items.count) files)" }.joined(separator: ", ")
            print("\(m.id)  \(m.source.hostname)  \(formatBytes(m.totalSize))  \(agents)")
        }
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore a snapshot. Shows the plan only, unless --apply is given."
    )
    @Option(name: .customLong("from"), help: "Folder that holds the AgentBackup/ directory.")
    var source: String
    @Option(help: "Snapshot ID (default: latest).")
    var snapshot: String?
    @OptionGroup var home: HomeOption
    @Option(name: .customLong("map"), help: ArgumentHelp(
        "Extra path mapping OLD=NEW, repeatable. `~` on the left is the source home, on the right the target home.",
        valueName: "old=new"))
    var maps: [String] = []
    @Option(help: "When a file or MCP server differs on both sides: keep | replace | rename.")
    var onConflict: String = ConflictPolicy.keep.rawValue
    @Flag(help: "List every file instead of a summary.")
    var verbose = false
    @Flag(help: "Actually write the files.")
    var apply = false

    func run() async throws {
        guard let policy = ConflictPolicy(rawValue: onConflict) else {
            throw ValidationError("--on-conflict must be one of: keep, replace, rename")
        }
        let engine = BackupEngine(store: LocalFolderStore(folder: expand(source)))
        let manifest = try await engine.store.manifest(id: snapshot)
        let targetHome = home.url

        let rules = try maps.map { spec -> PathMapper.Rule in
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--map expects OLD=NEW, got '\(spec)'") }
            func expandTilde(_ p: String, _ home: String) -> String { p == "~" || p.hasPrefix("~/") ? home + p.dropFirst() : p }
            return PathMapper.Rule(from: expandTilde(parts[0], manifest.source.home), to: expandTilde(parts[1], targetHome.path))
        }

        print("Snapshot \(manifest.id) from \(manifest.source.hostname)")
        print("Paths: \(manifest.source.home) → \(targetHome.path)")
        for rule in rules { print("       \(rule.from) → \(rule.to)") }

        let plans = try await engine.planRestore(manifest: manifest, targetHome: targetHome, extraRules: rules, policy: policy)
        for plan in plans {
            print("\n[\(plan.agentID)]")
            let byAction = Dictionary(grouping: plan.writes, by: \.action)
            for action in [PlannedWrite.Action.create, .update, .conflictKept, .unchanged] {
                guard let writes = byAction[action] else { continue }
                print("  \(action.rawValue): \(writes.count)")
                if verbose || action != .unchanged && writes.count <= 20 {
                    for w in writes { print("    \(displayPath(w.target, home: targetHome))\(w.detail.map { "  — \($0)" } ?? "")") }
                }
            }
            for note in plan.notes { print("  • \(note)") }
        }

        guard apply else {
            print("\nDry run — nothing written. Re-run with --apply to restore.")
            return
        }
        let result = try BackupEngine.apply(plans, home: targetHome)
        print("\nWrote \(result.written) files.")
        if let dir = result.rollbackDir { print("Rollback copies: \(dir.path)") }
    }

    func displayPath(_ url: URL, home: URL) -> String {
        url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }
}
