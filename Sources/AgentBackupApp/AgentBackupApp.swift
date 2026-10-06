import AgentBackupCore
import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `--render <dir>` writes PNGs of each screen with live data and exits (used for UI review in CI/agents).
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-wizard"), index + 3 < args.count {
            // --render-wizard <backup folder> <target home> <output dir>; passphrase from AGENT_BACKUP_PASSPHRASE.
            ScreenRenderer.runWizard(backup: URL(fileURLWithPath: args[index + 1]), home: URL(fileURLWithPath: args[index + 2]),
                                     outputDirectory: URL(fileURLWithPath: args[index + 3]))
        } else if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
            ScreenRenderer.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else {
            AgentBackupApp.main()
        }
    }
}

struct AgentBackupApp: App {
    @State private var model = AppModel()

    init() {
        // Lets `swift run AgentBackupApp` (no .app bundle) still get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Agent Backup") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("重新掃描") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.route }, set: { if let route = $0 { model.route = route } })) {
                Label("總覽", systemImage: "square.grid.2x2").tag(Route.overview)
                Section("Coding Agents") {
                    ForEach(model.installedAgents) { agent in
                        Label {
                            HStack {
                                Text(agent.name)
                                Spacer()
                                Text(Format.bytes(agent.backupBytes ?? agent.diskBytes))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: agent.symbol).foregroundStyle(agent.tint)
                        }
                        .tag(Route.agent(agent.id))
                    }
                }
                Section("備份") {
                    Label("Google Drive", systemImage: "icloud").tag(Route.drive)
                    Label("備份紀錄", systemImage: "clock.arrow.circlepath").tag(Route.snapshots)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            ScrollView {
                RouteView(route: model.route)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: {
                        if model.isScanning { ProgressView().controlSize(.small) } else { Label("重新掃描", systemImage: "arrow.clockwise") }
                    }
                    .help("重新偵測 agents 並檢查 Google Drive（⌘R）")
                }
            }
        }
        .sheet(item: $model.passphrasePrompt) { prompt in
            PassphraseSheet(prompt: prompt).environment(model)
        }
        .sheet(item: $model.restoreWizard) { wizard in
            RestoreWizardView(wizard: wizard)
        }
    }
}

struct RouteView: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        switch route {
        case .overview: OverviewView()
        case .agent(let id):
            if let agent = model.agent(id) { AgentDetailView(agent: agent) } else { OverviewView() }
        case .drive: DriveView()
        case .snapshots: SnapshotsView()
        }
    }
}

/// Renders each screen to PNG with real data, without opening a window.
@MainActor
enum ScreenRenderer {
    static func run(outputDirectory: URL) {
        _ = NSApplication.shared
        Task { @MainActor in
            let model = AppModel()
            await model.refresh()
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            var screens: [(String, Route)] = [("overview", .overview), ("drive", .drive), ("snapshots", .snapshots)]
            screens += model.installedAgents.map { ("agent-\($0.id)", .agent($0.id)) }
            for scheme in [ColorScheme.light, .dark] {
                for (name, route) in screens {
                    let view = RouteView(route: route)
                        .environment(model)
                        .frame(width: 1100)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1.5
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                    let file = outputDirectory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                    try? png.write(to: file)
                    print(file.path)
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Walks the restore wizard against a local backup folder, restoring into `home`.
    static func runWizard(backup: URL, home: URL, outputDirectory: URL) {
        _ = NSApplication.shared
        Task { @MainActor in
            do {
                let store = LocalFolderStore(folder: backup)
                guard let keyfile = try await BackupEngine.keyfile(in: store) else { throw BackupError.notInitialized }
                let vault = try Vault.unlock(keyfile, passphrase: ProcessInfo.processInfo.environment["AGENT_BACKUP_PASSPHRASE"] ?? "")
                let snapshots = try await store.snapshotIDs().compactMap(SnapshotRef.init).sorted { $0.date > $1.date }
                let wizard = RestoreWizardModel(app: nil, engine: BackupEngine(store: store, vault: vault),
                                                snapshots: snapshots, selected: nil, home: home)
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                while wizard.manifest == nil || wizard.isLoadingManifest { try await Task.sleep(nanoseconds: 50_000_000) }
                for step in RestoreWizardModel.Step.allCases {
                    if step != .snapshot { await wizard.next() }
                    if let error = wizard.error { print("error at \(step): \(error)") }
                    let renderer = ImageRenderer(content: RestoreWizardView(wizard: wizard, scrollable: false).background(Color(nsColor: .windowBackgroundColor)))
                    renderer.scale = 1.5
                    if let tiff = renderer.nsImage?.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let file = outputDirectory.appendingPathComponent("wizard-\(step.rawValue + 1)-\(step).png")
                        try png.write(to: file)
                        print(file.path)
                    }
                }
            } catch {
                print("render failed: \(error)")
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}
