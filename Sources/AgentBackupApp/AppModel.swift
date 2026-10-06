import AgentBackupCore
import AppKit
import Observation

enum Route: Hashable {
    case overview
    case agent(String)
    case drive
    case snapshots
}

struct SnapshotRef: Identifiable, Hashable {
    let id: String
    let date: Date
    let hostname: String

    init?(id: String) {
        guard let parsed = BackupEngine.parseSnapshotID(id) else { return nil }
        self.id = id
        date = parsed.date
        hostname = parsed.hostname
    }
}

enum PassphrasePrompt: Identifiable {
    case create
    case unlock(Keyfile)

    var id: String {
        switch self {
        case .create: "create"
        case .unlock(let keyfile): keyfile.fingerprint
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum DriveState {
        case checking
        /// No OAuth client installed yet.
        case notConfigured
        case loggedOut
        case connected(DriveStatus)
        case failed(String)
    }

    struct DriveStatus {
        var account: GoogleDriveStore.Account
        /// Whether a passphrase/keyfile exists in the Drive folder.
        var initialized: Bool
        var snapshots: [SnapshotRef]
    }

    enum BackupState {
        case idle
        case running(BackupProgress?)
        case finished(BackupResult)
        case failed(String)
    }

    let home: URL
    let secrets: SecretStore
    let keys: KeyManager

    var route: Route = .overview
    var agents: [AgentInfo] = []
    var isScanning = false
    var drive: DriveState = .checking
    var backupState: BackupState = .idle
    var passphrasePrompt: PassphrasePrompt?
    var isLoggingIn = false

    private var auth: GoogleOAuth?
    private var store: GoogleDriveStore?

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), secrets: SecretStore = KeychainStore()) {
        self.home = home
        self.secrets = secrets
        keys = KeyManager(secrets: secrets)
    }

    // MARK: - Derived

    var installedAgents: [AgentInfo] { agents.filter(\.installed) }
    var backupableAgents: [AgentInfo] { installedAgents.filter { $0.support == .supported } }
    var totalDiskBytes: Int { installedAgents.reduce(0) { $0 + $1.diskBytes } }
    var totalBackupBytes: Int { backupableAgents.reduce(0) { $0 + ($1.backupBytes ?? 0) } }

    var driveStatus: DriveStatus? {
        if case .connected(let status) = drive { return status }
        return nil
    }

    var latestSnapshot: SnapshotRef? { driveStatus?.snapshots.first }

    var isBackingUp: Bool {
        if case .running = backupState { return true }
        return false
    }

    var canBackUp: Bool { driveStatus != nil && !backupableAgents.isEmpty && !isBackingUp }

    func agent(_ id: String) -> AgentInfo? { agents.first { $0.id == id } }

    // MARK: - Refresh

    func refresh() async {
        async let scan: Void = scanAgents()
        async let drive: Void = refreshDrive()
        _ = await (scan, drive)
    }

    func scanAgents() async {
        isScanning = true
        let home = home
        agents = await Task.detached(priority: .userInitiated) { AgentCatalog.scan(home: home) }.value
        isScanning = false
    }

    func refreshDrive() async {
        guard let data = try? Data(contentsOf: GoogleClientConfig.defaultLocation(home: home)),
              let client = try? JSONDecoder().decode(GoogleClientConfig.self, from: data) else {
            drive = .notConfigured
            return
        }
        let auth = GoogleOAuth(client: client, secrets: secrets)
        self.auth = auth
        guard auth.isLoggedIn else {
            drive = .loggedOut
            return
        }
        if driveStatus == nil { drive = .checking }
        do {
            let store = GoogleDriveStore(tokens: auth)
            self.store = store
            let account = try await store.account()
            let initialized = try await BackupEngine.keyfile(in: store) != nil
            let snapshots = try await store.snapshotIDs().compactMap(SnapshotRef.init).sorted { $0.date > $1.date }
            drive = .connected(DriveStatus(account: account, initialized: initialized, snapshots: snapshots))
        } catch GoogleAuthError.notLoggedIn {
            drive = .loggedOut
        } catch {
            drive = .failed(error.localizedDescription)
        }
    }

    // MARK: - Google Drive

    /// Installs the OAuth client JSON downloaded from Google Cloud Console.
    func installClient(from url: URL) async throws {
        let config = try GoogleClientConfig.parse(googleJSON: try Data(contentsOf: url))
        let target = GoogleClientConfig.defaultLocation(home: home)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        await refreshDrive()
    }

    func login() async {
        guard let auth else { return }
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            try await auth.login { NSWorkspace.shared.open($0) }
            await refreshDrive()
        } catch {
            drive = .failed(error.localizedDescription)
        }
    }

    func logout() async {
        await auth?.logout()
        store = nil
        await refreshDrive()
    }

    // MARK: - Backup

    func startBackup() async {
        guard let store, canBackUp else { return }
        do {
            if let keyfile = try await BackupEngine.keyfile(in: store) {
                if let vault = keys.cachedVault(for: keyfile) {
                    await runBackup(store: store, vault: vault)
                } else {
                    passphrasePrompt = .unlock(keyfile)
                }
            } else {
                passphrasePrompt = .create
            }
        } catch {
            backupState = .failed(error.localizedDescription)
        }
    }

    /// Called by the passphrase sheet; throws so the sheet can show "wrong passphrase" inline.
    func submitPassphrase(_ passphrase: String) async throws {
        guard let store, let prompt = passphrasePrompt else { return }
        let keys = keys
        let vault: Vault
        switch prompt {
        case .unlock(let keyfile):
            // PBKDF2 with 600k iterations takes a moment; keep it off the main thread.
            vault = try await Task.detached { try keys.unlock(keyfile, passphrase: passphrase) }.value
        case .create:
            vault = try await keys.create(in: store, passphrase: passphrase)
        }
        passphrasePrompt = nil
        await runBackup(store: store, vault: vault)
    }

    private func runBackup(store: GoogleDriveStore, vault: Vault) async {
        backupState = .running(nil)
        let source = SourceInfo(
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            userName: home.lastPathComponent, home: home.path
        )
        do {
            let result = try await BackupEngine(store: store, vault: vault).backup(
                providers: Providers.all(home: home), source: source
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isBackingUp else { return }
                    self.backupState = .running(progress)
                }
            }
            backupState = .finished(result)
            await refreshDrive()
        } catch {
            backupState = .failed(error.localizedDescription)
        }
    }
}
