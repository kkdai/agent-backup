import AgentBackupCore
import SwiftUI

/// The launch screen: what's on this Mac, how big it is, and whether it's safely backed up.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            stats
            BackupPanel()
            agentGrid
        }
        .padding(24)
    }

    private var stats: some View {
        HStack(spacing: 14) {
            StatCard(
                title: "Coding Agents", symbol: "cpu",
                value: model.isScanning && model.agents.isEmpty ? "掃描中…" : "\(model.installedAgents.count) 個",
                detail: "已偵測 \(model.installedAgents.count) / \(model.agents.count) 種 · \(model.backupableAgents.count) 個可備份"
            )
            StatCard(
                title: "資料大小", symbol: "externaldrive",
                value: Format.bytes(model.totalBackupBytes),
                detail: "可備份 · 磁碟上共 \(Format.bytes(model.totalDiskBytes))（含快取）"
            )
            driveCard
            lastBackupCard
        }
    }

    private var driveCard: some View {
        let (value, detail, tint): (String, String, Color) = switch model.drive {
        case .checking: ("檢查中…", "正在連線 \(model.location.title)", .secondary)
        case .notConfigured: ("未設定", "需要先設定 OAuth client", .orange)
        case .loggedOut: ("未登入", "登入後即可備份", .orange)
        case .connected(let status): ("已連線", status.account.email ?? status.location.title, .green)
        case .failed(let message): ("連線失敗", message, .red)
        }
        return Button { model.route = .drive } label: {
            StatCard(title: model.location.title, symbol: model.location.symbol, value: value, detail: detail, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private var lastBackupCard: some View {
        let (value, detail): (String, String) =
            if let latest = model.latestSnapshot {
                (Format.relative(latest.date), "\(latest.hostname) · 雲端共 \(model.driveStatus?.snapshots.count ?? 0) 份備份")
            } else if model.driveStatus != nil {
                ("尚未備份", "\(model.location.title) 上還沒有備份")
            } else {
                ("—", "連線 \(model.location.title) 後顯示")
            }
        return Button { model.route = .snapshots } label: {
            StatCard(title: "上次備份", symbol: "clock.arrow.circlepath", value: value, detail: detail,
                     tint: model.latestSnapshot == nil ? .secondary : .primary)
        }
        .buttonStyle(.plain)
    }

    private var agentGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "這台 Mac 上的 Coding Agents",
                          trailing: model.isScanning ? "掃描中…" : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(model.agents) { agent in
                    Button { if agent.installed { model.route = .agent(agent.id) } } label: {
                        AgentCard(agent: agent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!agent.installed)
                }
            }
        }
    }
}

struct AgentCard: View {
    let agent: AgentInfo

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AgentIcon(agent: agent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name).font(.headline)
                        HStack(spacing: 4) {
                            SupportBadge(agent: agent)
                            if agent.isRunning { RunningBadge() }
                        }
                    }
                    Spacer()
                }
                if agent.installed {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("磁碟上", Format.bytes(agent.diskBytes))
                        if let backup = agent.backupBytes {
                            row("可備份", Format.bytes(backup))
                        }
                        if let sessions = agent.sessionCount, let projects = agent.projectCount {
                            row("聊天記錄", "\(sessions) 個 · \(projects) 個專案")
                        }
                        row("MCP servers", agent.mcpServers.isEmpty ? "無" : "\(agent.mcpServers.count) 個")
                    }
                    .font(.callout)
                } else {
                    Text("沒有在這台 Mac 上找到")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(minHeight: 150, alignment: .top)
        }
        .opacity(agent.installed ? 1 : 0.55)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// "Back up now" with live progress and result.
struct BackupPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(iconTint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    status
                }
                Spacer()
                Button {
                    Task { await model.startBackup() }
                } label: {
                    Label("立即備份", systemImage: "arrow.up.to.line")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canBackUp)
            }
        }
    }

    private var title: String {
        switch model.backupState {
        case .running: "正在備份到 \(model.location.title)…"
        case .finished: "備份完成"
        case .failed: "備份失敗"
        case .idle:
            model.driveStatus == nil ? "連線 \(model.location.title) 後就能備份"
                : "備份 \(model.backupableAgents.map(\.name).joined(separator: "、")) 到 \(model.location.title)"
        }
    }

    private var icon: String {
        switch model.backupState {
        case .running: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "lock.shield"
        }
    }

    private var iconTint: Color {
        switch model.backupState {
        case .finished: .green
        case .failed: .red
        default: .accentColor
        }
    }

    @ViewBuilder private var status: some View {
        switch model.backupState {
        case .running(let progress):
            if let progress, progress.filesTotal > 0 {
                ProgressView(value: Double(progress.filesDone), total: Double(progress.filesTotal)) {
                    Text("\(progress.filesDone) / \(progress.filesTotal) 個檔案 · 已上傳 \(Format.bytes(progress.bytesUploaded))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.small)
            }
        case .finished(let result):
            Text("\(result.fileCount) 個檔案（\(Format.bytes(result.manifest.totalSize))）· 新上傳 \(result.newBlobCount) 個（\(Format.bytes(result.uploadedBytes))），其餘沿用先前的備份")
                .font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
        case .idle:
            Text("端對端加密：先在這台 Mac 上用你的 passphrase 加密，雲端只會收到密文。只上傳有變動的部分。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
