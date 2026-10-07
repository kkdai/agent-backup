import AgentBackupCore
import SwiftUI

/// Every MCP server on this Mac × every agent: see where each one is set up, and add it elsewhere.
struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingCopy?

    struct PendingCopy: Identifiable {
        let server: MCPServer
        let agent: String
        let plan: MCPRegistry.CopyPlan
        var id: String { server.id + agent }
    }

    /// One row per server name; the reference config is the first agent's (in MCPRegistry order).
    private var rows: [(name: String, reference: MCPServer, owners: [String])] {
        var byName: [String: (MCPServer, [String])] = [:]
        var order: [String] = []
        for agent in agents {
            for server in model.mcpServers[agent] ?? [] {
                if byName[server.name] == nil {
                    byName[server.name] = (server, [])
                    order.append(server.name)
                }
                byName[server.name]!.1.append(agent)
            }
        }
        return order.map { ($0, byName[$0]!.0, byName[$0]!.1) }
    }

    private var agents: [String] { MCPRegistry.agentIDs.filter { model.mcpServers[$0] != nil } }

    private func name(_ agent: String) -> String { model.agent(agent)?.name ?? agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP servers").font(.largeTitle.weight(.semibold))
                Text("看哪些 agent 設定了哪些 MCP server，一鍵加到其他 agent。只在這台 Mac 上複製，API key 等設定值不會顯示。")
                    .foregroundStyle(.secondary)
            }
            if let message = model.mcpMessage {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Card { Text("這台 Mac 上的 agent 都還沒有設定 MCP server。").foregroundStyle(.secondary) }
            } else {
                matrix
                legend
            }
        }
        .padding(24)
        .confirmationDialog(pending.map { "把「\($0.server.name)」加到 \(name($0.agent))？" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { copy in
            Button("加入") { model.applyMCPCopy(copy.plan) }
        } message: { copy in
            let notes = copy.plan.warnings.map(warningText)
            Text((["會寫入 \(name(copy.agent)) 的設定檔，原檔會保留復原點。"] + notes).joined(separator: "\n"))
        }
    }

    private var matrix: some View {
        Card(padding: 0) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Server").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12)
                    ForEach(agents, id: \.self) { agent in
                        Text(name(agent)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 110).padding(.vertical, 12)
                    }
                }
                ForEach(rows, id: \.name) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(row.name).fontWeight(.medium)
                                Badge(text: row.reference.transport.rawValue, color: .blue)
                            }
                            Text(row.reference.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        ForEach(agents, id: \.self) { agent in
                            cell(row.reference, agent: agent).frame(width: 110)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ reference: MCPServer, agent: String) -> some View {
        let existing = (model.mcpServers[agent] ?? []).first { $0.name == reference.name }
        if let existing {
            let same = existing.sameConfig(as: reference)
            Image(systemName: same ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(same ? .green : .orange)
                .help(same ? "已設定" + (existing.project.map { "（專案 \(($0 as NSString).abbreviatingWithTildeInPath)）" } ?? "")
                           : "同名，但設定不同")
        } else {
            Button {
                do {
                    let plan = try model.planMCPCopy(reference, to: agent, replace: false)
                    if plan.write == nil {
                        model.mcpMessage = plan.warnings.map(warningText).joined(separator: "；")
                    } else {
                        pending = PendingCopy(server: reference, agent: agent, plan: plan)
                    }
                } catch {
                    model.mcpMessage = error.localizedDescription
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("加到 \(name(agent))")
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label("已設定", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("同名但設定不同", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Label("點一下加入", systemImage: "plus.circle").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func warningText(_ warning: MCPWarning) -> String {
        switch warning {
        case .unsupportedTransport(let agent, let transport): "\(agent) 不支援 \(transport.rawValue) 類型的 MCP server"
        case .wrappedWithMcpRemote: "這是遠端 server，會透過 npx mcp-remote 連線"
        case .droppedField(_, let field): "目標不支援 \(field)，已略過這個設定"
        case .serverExists(let server): "「\(server)」已存在，保留原本的設定"
        }
    }
}
