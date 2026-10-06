import CryptoKit
import Foundation

/// Google Gemini CLI (`~/.gemini`).
///
/// Backed up: `settings.json` (MCP servers and preferences), `GEMINI.md`, `commands/`,
/// `projects.json`, `trustedFolders.json`, and per project under `tmp/<slug>/`: the chats,
/// the prompt log (`logs.json`), tool outputs and `.project_root`.
///
/// Never backed up: login (`oauth_creds.json`, `google_accounts.json`), `installation_id`,
/// `state.json`, checkpoint shadow git repos (`history/`), extensions (reinstall them),
/// `tmp/bin`, and `antigravity-cli/` (a different product).
///
/// Each session records `projectHash` = SHA-256 of the project path; when a restore moves a
/// project, the hash is rewritten too so Gemini still finds the session for that project.
public struct GeminiProvider: AgentProvider {
    public let id = "gemini-cli"
    public let displayName = "Gemini CLI"
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    var geminiDir: URL { home.appendingPathComponent(".gemini", isDirectory: true) }
    var tmpDir: URL { geminiDir.appendingPathComponent("tmp", isDirectory: true) }

    static let files: [(String, ItemKind)] = [
        ("settings.json", .settings),
        ("GEMINI.md", .instructions),
        ("projects.json", .settings),
        ("trustedFolders.json", .settings),
    ]

    public func isInstalled() -> Bool { fileExists(geminiDir) }

    // MARK: - Backup

    public func collect() throws -> [CollectedFile] {
        var out: [CollectedFile] = []
        for (name, kind) in Self.files {
            let url = geminiDir.appendingPathComponent(name)
            if fileExists(url) {
                out.append(CollectedFile(kind: kind, path: ".gemini/\(name)", modifiedAt: modificationDate(url), source: .file(url)))
            }
        }
        for file in walkFiles(geminiDir.appendingPathComponent("commands")) {
            out.append(CollectedFile(kind: .command, path: ".gemini/commands/\(file.path)",
                                     modifiedAt: modificationDate(file.url), source: .file(file.url)))
        }

        let slugs = ((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []).sorted()
        for slug in slugs where slug != "bin" {
            let dir = tmpDir.appendingPathComponent(slug)
            let rootFile = dir.appendingPathComponent(".project_root")
            guard fileExists(rootFile) else { continue }   // only real project folders
            let projectPath = (try? String(contentsOf: rootFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = ProjectRef(dirName: slug, path: projectPath)
            for file in walkFiles(dir) {
                let kind: ItemKind =
                    if file.path.hasPrefix("chats/") { .session }
                    else if file.path == "logs.json" { .history }
                    else { .sessionArtifact }
                out.append(CollectedFile(kind: kind, path: ".gemini/tmp/\(slug)/\(file.path)", project: project,
                                         modifiedAt: modificationDate(file.url), source: .file(file.url)))
            }
        }
        return out
    }

    public func summary() throws -> AgentSummary {
        let files = try collect()
        var bytesByKind: [ItemKind: Int] = [:]
        for file in files {
            if case .file(let url) = file.source {
                bytesByKind[file.kind, default: 0] += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
        }
        return AgentSummary(
            agentID: id, displayName: displayName,
            projectCount: Set(files.compactMap { $0.project?.path }).count,
            sessionCount: files.filter { $0.kind == .session }.count,
            totalBytes: bytesByKind.values.reduce(0, +), bytesByKind: bytesByKind,
            mcpServers: AgentCatalog.jsonMCP(geminiDir.appendingPathComponent("settings.json"))
        )
    }

    static func projectHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Restore

    public func planRestore(items: [SnapshotItem], context: RestoreContext) async throws -> RestorePlan {
        var plan = RestorePlan(agentID: id)
        for item in items {
            let target = home.appendingPathComponent(item.path)
            var data = context.mapper.rewrite(try await context.load(item))
            if let original = item.project?.path {
                let moved = context.mapper.map(path: original)
                if moved != original, var text = String(data: data, encoding: .utf8) {
                    text = text.replacingOccurrences(of: Self.projectHash(original), with: Self.projectHash(moved))
                    data = Data(text.utf8)
                }
            }

            switch item.path {
            case ".gemini/settings.json":
                plan.writes.append(try planSettingsMerge(data, target: target, policy: context.policy, notes: &plan.notes))

            case ".gemini/projects.json":
                plan.writes.append(try planJSONMerge(target: target, kind: .settings, detail: "merged project list") { local in
                    var root = local ?? [:]
                    let incoming = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["projects"] as? [String: Any] ?? [:]
                    let current = root["projects"] as? [String: Any] ?? [:]
                    root["projects"] = current.merging(incoming) { local, _ in local }
                    return root
                })
            case ".gemini/trustedFolders.json":
                plan.writes.append(try planJSONMerge(target: target, kind: .settings, detail: "merged trusted folders") { local in
                    let incoming = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    return (local ?? [:]).merging(incoming) { local, _ in local }
                })
            case let path where path.hasSuffix("/logs.json"):
                plan.writes.append(try planJSONMerge(target: target, kind: .history, detail: "merged with this Mac's prompt log") { local in
                    Self.mergeLogs(local: (try? Data(contentsOf: target)), incoming: data)
                })
            default:
                plan.writes.append(planFileWrite(
                    target: target, data: data, kind: item.kind, modifiedAt: item.modifiedAt,
                    policy: context.policy, appendOnly: item.kind == .session && item.path.hasSuffix(".jsonl")
                ))
            }
        }
        plan.notes.append(.quitBeforeApplying(agent: displayName))
        plan.notes.append(.logInAfterRestore(agent: displayName, command: "gemini"))
        return plan
    }

    /// `logs.json` is an array of prompt entries; union them, ordered by timestamp.
    static func mergeLogs(local: Data?, incoming: Data) -> [Any] {
        let parse = { (data: Data?) -> [[String: Any]] in
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        }
        var seen: [Any] = []
        for entry in parse(local) + parse(incoming) where !seen.contains(where: { jsonEqual($0, entry) }) {
            seen.append(entry)
        }
        return seen.enumerated().sorted { a, b in
            let ta = ((a.element as? [String: Any])?["timestamp"] as? String) ?? ""
            let tb = ((b.element as? [String: Any])?["timestamp"] as? String) ?? ""
            return (ta, a.offset) < (tb, b.offset)
        }.map(\.element)
    }
}
