import Foundation

/// One coding agent (Claude Code, Codex, …): knows where its data lives,
/// how to collect it, and how to put a snapshot back on a (possibly different) machine.
public protocol AgentProvider {
    var id: String { get }
    var displayName: String { get }
    var home: URL { get }

    func isInstalled() -> Bool
    func summary() throws -> AgentSummary
    func collect() throws -> [CollectedFile]
    func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan
}

public enum Providers {
    public static func all(home: URL) -> [AgentProvider] {
        [ClaudeCodeProvider(home: home)]
    }

    public static func provider(id: String, home: URL) -> AgentProvider? {
        all(home: home).first { $0.id == id }
    }
}

public struct CollectedFile {
    public enum Source {
        case file(URL)
        case data(Data)
    }

    public var kind: ItemKind
    public var path: String
    public var project: ProjectRef?
    public var modifiedAt: Date?
    public var source: Source

    public func read() throws -> Data {
        switch source {
        case .file(let url): try Data(contentsOf: url)
        case .data(let data): data
        }
    }
}

public struct AgentSummary {
    public var agentID: String
    public var displayName: String
    public var projectCount: Int
    public var sessionCount: Int
    public var totalBytes: Int
    public var bytesByKind: [ItemKind: Int]
    public var mcpServers: [MCPServerInfo]
}

/// Agent-neutral view of an MCP server. The basis for cross-agent MCP copying (M3).
public struct MCPServerInfo: Equatable, Identifiable {
    public enum Transport: String {
        case stdio, http, sse, unknown
    }

    public var name: String
    /// `nil` for user scope, otherwise the project path.
    public var project: String?
    public var transport: Transport
    /// Command line for stdio, URL for http/sse. Never includes env or header values.
    public var target: String

    public var id: String { "\(project ?? "")\u{0}\(name)" }

    init(name: String, project: String?, config: [String: Any]) {
        self.name = name
        self.project = project
        let type = config["type"] as? String
        if let url = config["url"] as? String {
            transport = Transport(rawValue: type ?? "http") ?? .unknown
            target = url
        } else if let command = config["command"] as? String {
            transport = .stdio
            target = ([command] + (config["args"] as? [String] ?? [])).joined(separator: " ")
        } else {
            transport = .unknown
            target = ""
        }
    }
}

public enum ConflictPolicy: String, CaseIterable {
    /// Keep what is already on this Mac.
    case keep
    /// Overwrite with the backup (the old file goes to the rollback folder).
    case replace
    /// Keep both: the backup copy is written next to it with a `.restored` / `-restored` suffix.
    case rename
}

public struct RestoreContext {
    public var mapper: PathMapper
    public var policy: ConflictPolicy
    public var load: (SnapshotItem) async throws -> Data

    public init(mapper: PathMapper, policy: ConflictPolicy, load: @escaping (SnapshotItem) async throws -> Data) {
        self.mapper = mapper
        self.policy = policy
        self.load = load
    }
}

public struct RestorePlan {
    public var agentID: String
    public var writes: [PlannedWrite] = []
    /// Things the user has to do by hand (log in, reinstall plugins, …).
    public var notes: [String] = []

    public init(agentID: String) {
        self.agentID = agentID
    }
}

public struct PlannedWrite {
    public enum Action: String {
        case create, update, unchanged
        /// Both sides changed and policy is `keep`: nothing is written.
        case conflictKept
    }

    public var target: URL
    public var data: Data
    public var kind: ItemKind
    public var action: Action
    public var detail: String?
    public var modifiedAt: Date?

    public var writes: Bool { action == .create || action == .update }
}
