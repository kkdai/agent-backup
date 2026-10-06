import AgentBackupCore
import AppKit
import SwiftUI

struct AgentDetailView: View {
    let agent: AgentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            HStack(spacing: 14) {
                StatCard(title: "磁碟上", symbol: "internaldrive", value: Format.bytes(agent.diskBytes), detail: "所有檔案，含快取與 log")
                StatCard(title: "可備份", symbol: "arrow.up.doc",
                         value: agent.backupBytes.map(Format.bytes) ?? "—",
                         detail: agent.backupBytes == nil ? "這個 agent 還不支援備份" : "設定、聊天記錄、記憶等")
                StatCard(title: "聊天記錄", symbol: "bubble.left.and.bubble.right",
                         value: agent.sessionCount.map { "\($0) 個" } ?? "—",
                         detail: agent.projectCount.map { "分布在 \($0) 個專案" } ?? "支援後顯示")
                StatCard(title: "MCP servers", symbol: "point.3.connected.trianglepath.dotted",
                         value: "\(agent.mcpServers.count) 個", detail: "全域與各專案")
            }
            if let issueURL = agent.issueURL { plannedNotice(issueURL) }
            if !agent.bytesByKind.isEmpty { breakdown }
            mcpServers
            locations
        }
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AgentIcon(agent: agent, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(.largeTitle.weight(.semibold))
                SupportBadge(agent: agent)
            }
        }
    }

    private func plannedNotice(_ url: URL) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "hammer").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(agent.name) 的備份還在開發中").font(.headline)
                    Text("目前先顯示偵測結果與 MCP 設定，備份會在後續版本支援。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Link("查看進度", destination: url)
            }
        }
    }

    private var breakdown: some View {
        let total = max(1, agent.bytesByKind.values.reduce(0, +))
        let rows = agent.bytesByKind.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "備份內容", trailing: "共 \(Format.bytes(total))")
            Card {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(rows, id: \.key) { kind, bytes in
                        GridRow {
                            Label(kind.chineseLabel, systemImage: kind.symbol)
                            ShareBar(fraction: Double(bytes) / Double(total), tint: agent.tint)
                                .frame(minWidth: 160)
                            Text(Format.bytes(bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            Text("登入資訊、快取、telemetry 不會備份；到新電腦後重新登入即可。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mcpServers: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "MCP servers")
            Card {
                if agent.mcpServers.isEmpty {
                    Text("沒有設定 MCP server").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("名稱"); Text("類型"); Text("範圍"); Text("目標")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach(agent.mcpServers) { server in
                            GridRow {
                                Text(server.name).fontWeight(.medium)
                                Badge(text: server.transport.rawValue, color: .blue)
                                Text(server.project.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "全域")
                                    .foregroundStyle(.secondary)
                                Text(server.target)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            Text("只顯示指令與網址；環境變數與 header（API key）不會顯示。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "檔案位置")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agent.locations, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text((url.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced())
                            Spacer()
                            Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }
}
