import AgentBackupCore
import AppKit
import ArgumentParser
import Foundation

@main
struct AgentBackupCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-backup",
        abstract: "Back up coding-agent MCP configs and sessions, and restore them on another Mac.",
        discussion: """
        A backup LOCATION is either `gdrive` (My Drive/AgentBackup) or a local folder path.
        Everything stored there is encrypted with a key protected by your passphrase.
        Set AGENT_BACKUP_PASSPHRASE to skip the prompt; AGENT_BACKUP_NO_KEYCHAIN=1 to not cache the unlocked key.
        """,
        subcommands: [Detect.self, Backup.self, Snapshots.self, Restore.self, Lock.self, Drive.self]
    )
}

// MARK: - Shared

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

let secrets: SecretStore = KeychainStore()
let cachesKeys = ProcessInfo.processInfo.environment["AGENT_BACKUP_NO_KEYCHAIN"] != "1"

func openStore(_ location: String) throws -> BackupStore {
    guard location == "gdrive" else { return LocalFolderStore(folder: expand(location)) }
    return GoogleDriveStore(tokens: try googleAuth())
}

func googleAuth() throws -> GoogleOAuth {
    let url = GoogleClientConfig.defaultLocation()
    guard let data = try? Data(contentsOf: url) else {
        throw ValidationError("Google Drive isn't set up. Run `agent-backup drive setup --client-json <file>` first.")
    }
    return GoogleOAuth(client: try JSONDecoder().decode(GoogleClientConfig.self, from: data), secrets: secrets)
}

func readPassphrase(_ prompt: String) throws -> String {
    if let env = ProcessInfo.processInfo.environment["AGENT_BACKUP_PASSPHRASE"], !env.isEmpty { return env }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        throw ValidationError("No terminal to ask for the passphrase; set AGENT_BACKUP_PASSPHRASE.")
    }
    return String(cString: buffer)
}

/// Unlocks the location's key: Keychain cache first, then the passphrase. Creates a new key when allowed.
func openVault(_ store: BackupStore, createIfMissing: Bool) async throws -> Vault {
    if let keyfile = try await BackupEngine.keyfile(in: store) {
        let account = "vault-\(keyfile.fingerprint)"
        if cachesKeys, let raw = secrets.get(account) { return Vault(rawKey: raw) }
        let vault = try Vault.unlock(keyfile, passphrase: try readPassphrase("Passphrase for \(store.displayName): "))
        if cachesKeys { try? secrets.set(account, vault.rawKey) }
        return vault
    }
    guard createIfMissing else { throw BackupError.notInitialized }

    print("New backup location: \(store.displayName)")
    print("Choose a passphrase. You'll need it on the new Mac — if it's lost, the backup can't be decrypted.")
    let passphrase = try readPassphrase("New passphrase: ")
    guard passphrase.count >= 8 else { throw ValidationError("Use at least 8 characters.") }
    if ProcessInfo.processInfo.environment["AGENT_BACKUP_PASSPHRASE"] == nil,
       try readPassphrase("Repeat passphrase: ") != passphrase {
        throw ValidationError("Passphrases don't match.")
    }
    let (vault, keyfile) = try await BackupEngine.initialize(store, passphrase: passphrase)
    if cachesKeys { try? secrets.set("vault-\(keyfile.fingerprint)", vault.rawKey) }
    return vault
}

// MARK: - Commands

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
    static let configuration = CommandConfiguration(abstract: "Create an encrypted snapshot.")
    @Option(name: .customLong("to"), help: "Backup location: `gdrive` or a folder.")
    var location: String
    @OptionGroup var home: HomeOption

    func run() async throws {
        let homeURL = home.url
        let store = try openStore(location)
        let engine = BackupEngine(store: store, vault: try await openVault(store, createIfMissing: true))
        let source = SourceInfo(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            userName: homeURL.lastPathComponent, home: homeURL.path
        )
        let result = try await engine.backup(providers: Providers.all(home: homeURL), source: source)
        print("Snapshot \(result.manifest.id) → \(store.displayName)")
        for agent in result.manifest.agents {
            let counts = Dictionary(grouping: agent.items, by: \.kind)
            let parts = ItemKind.allCases.compactMap { kind in counts[kind].map { "\($0.count) \(kind.label.lowercased())" } }
            print("  \(agent.agentID): \(parts.joined(separator: ", "))")
        }
        print("\(result.fileCount) files (\(formatBytes(result.manifest.totalSize))); uploaded \(result.newBlobCount) new blobs (\(formatBytes(result.uploadedBytes))).")
    }
}

struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List snapshots.")
    @Option(name: .customLong("from"), help: "Backup location: `gdrive` or a folder.")
    var location: String

    func run() async throws {
        let store = try openStore(location)
        let engine = BackupEngine(store: store, vault: try await openVault(store, createIfMissing: false))
        let manifests = try await engine.manifests()
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
    @Option(name: .customLong("from"), help: "Backup location: `gdrive` or a folder.")
    var location: String
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
        let store = try openStore(location)
        let engine = BackupEngine(store: store, vault: try await openVault(store, createIfMissing: false))
        let manifest = try await engine.manifest(id: snapshot)
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

struct Lock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Forget the unlocked key cached in Keychain for a location.")
    @Option(name: .customLong("from"), help: "Backup location: `gdrive` or a folder.")
    var location: String

    func run() async throws {
        guard let keyfile = try await BackupEngine.keyfile(in: try openStore(location)) else {
            throw BackupError.notInitialized
        }
        secrets.delete("vault-\(keyfile.fingerprint)")
        print("Locked. The passphrase will be asked next time.")
    }
}

struct Drive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect to Google Drive.",
        subcommands: [Setup.self, Login.self, Status.self, Logout.self]
    )

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the OAuth client JSON downloaded from Google Cloud Console.")
        @Option(help: "Path to the downloaded client_secret_….json (\"Desktop app\" client).")
        var clientJson: String

        func run() throws {
            let config = try GoogleClientConfig.parse(googleJSON: try Data(contentsOf: expand(clientJson)))
            let target = GoogleClientConfig.defaultLocation()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            print("Saved OAuth client \(config.clientID.prefix(12))… to \(target.path)")
            print("Next: agent-backup drive login")
        }
    }

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Log in with your browser.")

        func run() async throws {
            let auth = try googleAuth()
            try await auth.login { url in
                print("Opening your browser to log in to Google…\nIf it doesn't open, visit:\n\(url.absoluteString)\n")
                NSWorkspace.shared.open(url)
            }
            print("Logged in. Backups go to My Drive/AgentBackup (this app can only see files it created).")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the Google Drive connection.")

        func run() async throws {
            let auth = try googleAuth()
            guard auth.isLoggedIn else { throw GoogleAuthError.notLoggedIn }
            let store = GoogleDriveStore(tokens: auth)
            let initialized = try await BackupEngine.keyfile(in: store) != nil
            let count = try await store.snapshotIDs().count
            print("Connected. \(store.displayName): \(initialized ? "\(count) snapshots" : "empty (first backup will set the passphrase)").")
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke and forget the Google login.")

        func run() async throws {
            await (try googleAuth()).logout()
            print("Logged out.")
        }
    }
}
