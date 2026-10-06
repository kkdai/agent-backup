import Foundation

/// One backup snapshot. Stored encrypted as `AgentBackup/snapshots/<id>`;
/// file contents live in content-addressed blobs so unchanged files are never re-uploaded.
public struct Manifest: Codable, Equatable {
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var id: String
    public var createdAt: Date
    public var source: SourceInfo
    public var agents: [AgentSnapshot]

    public init(id: String, createdAt: Date, source: SourceInfo, agents: [AgentSnapshot]) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.agents = agents
    }

    public var totalSize: Int { agents.flatMap(\.items).reduce(0) { $0 + $1.size } }
}

public struct SourceInfo: Codable, Equatable {
    public var hostname: String
    public var userName: String
    /// Absolute home directory on the source machine; the default path-mapping rule maps it to the target home.
    public var home: String

    public init(hostname: String, userName: String, home: String) {
        self.hostname = hostname
        self.userName = userName
        self.home = home
    }
}

public struct AgentSnapshot: Codable, Equatable {
    public var agentID: String
    public var items: [SnapshotItem]

    public init(agentID: String, items: [SnapshotItem]) {
        self.agentID = agentID
        self.items = items
    }
}

public struct SnapshotItem: Codable, Equatable {
    public var kind: ItemKind
    /// Relative to the home directory, or to the project's session directory when `project` is set.
    public var path: String
    public var project: ProjectRef?
    /// Keyed HMAC-SHA256 of the plaintext content (see `Vault.blobID`).
    public var blob: String
    public var size: Int
    public var modifiedAt: Date?

    public init(kind: ItemKind, path: String, project: ProjectRef?, blob: String, size: Int, modifiedAt: Date?) {
        self.kind = kind
        self.path = path
        self.project = project
        self.blob = blob
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// A project an agent keeps per-project data for.
public struct ProjectRef: Codable, Hashable {
    /// The agent's on-disk directory name for this project (e.g. `-Users-me-Code-app`).
    public var dirName: String
    /// The original absolute project path, when it could be recovered. Encoded
    /// directory names are lossy, so this is what path mapping is applied to.
    public var path: String?

    public init(dirName: String, path: String?) {
        self.dirName = dirName
        self.path = path
    }
}

public enum ItemKind: String, Codable, CaseIterable {
    case settings
    case instructions
    case mcpConfig
    case session
    case sessionArtifact
    case memory
    case history
    case skill
    case command
    case subagent
    case outputStyle
    case pluginManifest

    public var label: String {
        switch self {
        case .settings: "Settings"
        case .instructions: "Instructions"
        case .mcpConfig: "MCP config"
        case .session: "Sessions"
        case .sessionArtifact: "Session attachments"
        case .memory: "Memory"
        case .history: "Prompt history"
        case .skill: "Skills"
        case .command: "Commands"
        case .subagent: "Subagents"
        case .outputStyle: "Output styles"
        case .pluginManifest: "Plugin list"
        }
    }
}
