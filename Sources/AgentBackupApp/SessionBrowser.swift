import AgentBackupCore
import Observation
import SwiftUI

/// Reads the conversations inside a backup, decrypted in memory only.
@MainActor @Observable
final class SessionBrowserModel: Identifiable {
    struct Session: Identifiable {
        let id: String
        let agentID: String
        let project: String?
        let modifiedAt: Date?
        let messages: [TranscriptMessage]
        var title: String { SessionReader.title(messages) ?? "（沒有文字訊息）" }
    }

    let id = UUID()
    let engine: BackupEngine
    let snapshot: SnapshotRef
    var sessions: [Session] = []
    var loaded = 0
    var total = 0
    var isLoading = true
    var error: String?
    var query = ""
    var selectedID: String?

    init(engine: BackupEngine, snapshot: SnapshotRef) {
        self.engine = engine
        self.snapshot = snapshot
    }

    func load() async {
        do {
            let manifest = try await engine.manifest(id: snapshot.id)
            let items = manifest.agents.flatMap { agent in agent.items.filter { $0.kind == .session }.map { (agent.agentID, $0) } }
            total = items.count
            var out: [Session] = []
            for (agentID, item) in items {
                let data = try engine.vault.open(try await engine.store.blob(item.blob), expectedID: item.blob)
                if let messages = SessionReader.transcript(agentID: agentID, path: item.path, data: data), !messages.isEmpty {
                    out.append(Session(id: agentID + item.path, agentID: agentID, project: item.project?.path,
                                       modifiedAt: item.modifiedAt, messages: messages))
                }
                loaded += 1
            }
            sessions = out.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            selectedID = sessions.first?.id
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { session in
            session.messages.contains { $0.text.localizedCaseInsensitiveContains(q) } || (session.project ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var selected: Session? { sessions.first { $0.id == selectedID } }

    func matches(in session: Session) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? 0 : session.messages.filter { $0.text.localizedCaseInsensitiveContains(q) }.count
    }
}

struct SessionBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var browser: SessionBrowserModel
    /// False only for `--render-sessions`: ImageRenderer can't draw ScrollView contents.
    var fixedHeight = true

    @ViewBuilder private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if fixedHeight { ScrollView { content() } } else { content() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("瀏覽備份").font(.title2.weight(.semibold))
                    Text("\(Format.dateTime(browser.snapshot.date)) · \(browser.snapshot.hostname) · 只在記憶體中解密，不會寫到磁碟")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜尋聊天內容或專案", text: $browser.query).textFieldStyle(.roundedBorder).frame(width: 260)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if browser.isLoading {
                VStack(spacing: 10) {
                    ProgressView(value: Double(browser.loaded), total: Double(max(browser.total, 1)))
                        .frame(width: 280)
                    Text("下載並解密 \(browser.loaded) / \(browser.total) 個聊天記錄…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = browser.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 320, alignment: .top).frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    transcript.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(width: 1040, height: fixedHeight ? 700 : nil)
        .task { if browser.isLoading { await browser.load() } }
    }

    private var list: some View {
        let sessions = browser.filtered
        return scrolling {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(browser.query.isEmpty ? "\(sessions.count) 個聊天記錄" : "符合的聊天記錄：\(sessions.count)")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
                ForEach(sessions) { session in
                    Button { browser.selectedID = session.id } label: { row(session) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ session: SessionBrowserModel.Session) -> some View {
        let isSelected = session.id == browser.selectedID
        return VStack(alignment: .leading, spacing: 3) {
            Text(session.title).fontWeight(.medium).lineLimit(2)
            HStack(spacing: 6) {
                Text(agentName(session.agentID))
                if let project = session.project { Text("· " + (project as NSString).lastPathComponent) }
                if let date = session.modifiedAt { Text("· " + Format.relative(date)) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            let matches = browser.matches(in: session)
            if matches > 0 { Badge(text: "\(matches) 則符合", color: .orange) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var transcript: some View {
        if let session = browser.selected {
            scrolling {
                VStack(alignment: .leading, spacing: 12) {
                    if let project = session.project {
                        Label((project as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(SessionReader.foldingToolRuns(session.messages).prefix(fixedHeight ? .max : 12).enumerated()), id: \.offset) { _, message in
                        MessageBubble(message: message, query: browser.query)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(browser.sessions.isEmpty ? "這份備份沒有可閱讀的聊天記錄" : "選一個聊天記錄").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func agentName(_ id: String) -> String {
        Providers.provider(id: id, home: URL(fileURLWithPath: NSHomeDirectory()))?.displayName ?? id
    }
}

private struct MessageBubble: View {
    let message: TranscriptMessage
    let query: String

    var body: some View {
        switch message.role {
        case .tool:
            Label(message.text, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "你" : "Agent").font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == .user ? Color.accentColor : .secondary)
                Text(highlighted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Very long messages are shortened; matches are highlighted.
    private var highlighted: AttributedString {
        let text = message.text.count > 6000 ? String(message.text.prefix(6000)) + "\n…" : message.text
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: q, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.5)
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }
}
