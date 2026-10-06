import AgentBackupCore
import SwiftUI

// MARK: - Formatting

enum Format {
    static let locale = Locale(identifier: "zh-Hant-TW")

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

// MARK: - Agent appearance

extension AgentInfo {
    var symbol: String {
        switch id {
        case "claude-code": "terminal.fill"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini-cli": "sparkles"
        case "copilot-cli": "person.2.fill"
        case "claude-desktop": "macwindow"
        case "cursor": "cursorarrow.rays"
        default: "cpu"
        }
    }

    var tint: Color {
        switch id {
        case "claude-code", "claude-desktop": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(red: 0.06, green: 0.64, blue: 0.5)
        case "gemini-cli": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "copilot-cli": Color(red: 0.55, green: 0.36, blue: 0.86)
        default: .gray
        }
    }

    var issueURL: URL? {
        guard case .planned(let issue) = support else { return nil }
        return URL(string: "https://github.com/kkdai/agent-backup/issues/\(issue)")
    }
}

extension ItemKind {
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .instructions: "doc.text"
        case .mcpConfig: "point.3.connected.trianglepath.dotted"
        case .session: "bubble.left.and.bubble.right"
        case .sessionArtifact: "paperclip"
        case .memory: "brain"
        case .history: "clock"
        case .skill: "wand.and.stars"
        case .command: "command"
        case .subagent: "person.crop.rectangle.stack"
        case .outputStyle: "paintbrush"
        case .pluginManifest: "puzzlepiece.extension"
        }
    }

    var chineseLabel: String {
        switch self {
        case .settings: "設定"
        case .instructions: "全域指示（CLAUDE.md）"
        case .mcpConfig: "MCP 設定"
        case .session: "聊天記錄"
        case .sessionArtifact: "聊天附件"
        case .memory: "記憶"
        case .history: "輸入歷史"
        case .skill: "Skills"
        case .command: "自訂指令"
        case .subagent: "Subagents"
        case .outputStyle: "輸出風格"
        case .pluginManifest: "Plugin 清單"
        }
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var tint: Color = .accentColor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
    }
}

struct AgentIcon: View {
    let agent: AgentInfo
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: agent.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(agent.installed ? agent.tint : .gray.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct SupportBadge: View {
    let agent: AgentInfo

    var body: some View {
        if !agent.installed {
            Badge(text: "未安裝", color: .secondary)
        } else if case .planned(let issue) = agent.support {
            Badge(text: "即將支援 #\(issue)", color: .orange)
        } else {
            Badge(text: "可備份", color: .green)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// Horizontal share bar used for size breakdowns.
struct ShareBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}
