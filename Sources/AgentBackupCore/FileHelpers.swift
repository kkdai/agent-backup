import Foundation

/// Lists regular files under `dir`, following symlinks (a symlinked skill is backed up by
/// content, since its target usually doesn't exist on the new Mac). Paths are relative and sorted.
func walkFiles(_ dir: URL, excludingTopLevel excluded: Set<String> = []) -> [(path: String, url: URL)] {
    var out: [(String, URL)] = []
    var visited = Set<String>()

    func visit(_ dir: URL, prefix: String, depth: Int) {
        let real = dir.resolvingSymlinksInPath().path
        guard depth < 32, visited.insert(real).inserted,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where name != ".DS_Store" {
            if prefix.isEmpty && excluded.contains(name) { continue }
            let resolved = dir.appendingPathComponent(name).resolvingSymlinksInPath()
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                visit(resolved, prefix: rel, depth: depth + 1)
            } else {
                out.append((rel, resolved))
            }
        }
    }

    visit(dir, prefix: "", depth: 0)
    return out
}

func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func readJSONObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Never escape `/`, so serialized paths stay matchable by `PathMapper.rewrite`.
func serializeJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

/// Decides what to do with one restored file against what's already on disk.
/// `appendOnly` files (session transcripts) are compared by prefix: the longer one is newer.
func planFileWrite(
    target: URL, data: Data, kind: ItemKind, modifiedAt: Date?,
    policy: ConflictPolicy, appendOnly: Bool = false
) -> PlannedWrite {
    func write(_ action: PlannedWrite.Action, _ detail: String? = nil, to url: URL = target) -> PlannedWrite {
        PlannedWrite(target: url, data: data, kind: kind, action: action, detail: detail, modifiedAt: modifiedAt)
    }

    guard let local = try? Data(contentsOf: target) else { return write(.create) }
    if local == data { return write(.unchanged) }
    if appendOnly {
        if data.starts(with: local) { return write(.update, "backup has newer messages") }
        if local.starts(with: data) { return write(.unchanged, "this Mac has newer messages") }
    }
    switch policy {
    case .keep: return write(.conflictKept, "differs from this Mac; kept local")
    case .replace: return write(.update, "differs from this Mac; replaced")
    case .rename:
        let ext = target.pathExtension
        let base = target.deletingPathExtension().lastPathComponent
        let aside = target.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(base).restored" : "\(base).restored.\(ext)")
        return planFileWrite(target: aside, data: data, kind: kind, modifiedAt: modifiedAt, policy: .replace)
    }
}

/// Union of two JSONL histories, de-duplicated by line and ordered by a numeric timestamp field.
func planJSONLMerge(incoming: Data, target: URL, timestampKey: String, kind: ItemKind) -> PlannedWrite {
    let localData = try? Data(contentsOf: target)
    let lines = { (data: Data?) -> [Substring] in
        String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\n").filter { !$0.isEmpty }
    }
    var seen = Set<Substring>()
    let merged = (lines(localData) + lines(incoming)).filter { seen.insert($0).inserted }
    let timestamp = { (line: Substring) -> Double in
        ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?[timestampKey] as? Double ?? 0
    }
    let sorted = merged.enumerated()
        .sorted { (timestamp($0.element), $0.offset) < (timestamp($1.element), $1.offset) }
        .map(\.element)
    let data = Data((sorted.joined(separator: "\n") + "\n").utf8)
    let action: PlannedWrite.Action = localData == nil ? .create : localData == data ? .unchanged : .update
    return PlannedWrite(target: target, data: data, kind: kind, action: action,
                        detail: "merged with this Mac's history", modifiedAt: nil)
}

/// Server-by-server MCP merge shared by every agent whose config is JSON `{"name": {...}}`.
func mergeMCPServers(
    _ incoming: [String: Any], into current: [String: Any], scope: String?,
    policy: ConflictPolicy, conflicts: inout [RestoreNote]
) -> [String: Any] {
    var merged = current
    for (name, config) in incoming {
        guard let local = merged[name] else {
            merged[name] = config
            continue
        }
        if jsonEqual(local, config) { continue }
        switch policy {
        case .keep: conflicts.append(.mcpConflictKept(server: name, scope: scope))
        case .replace: merged[name] = config
        case .rename: merged["\(name)-restored"] = config
        }
    }
    return merged
}

func jsonEqual(_ a: Any, _ b: Any) -> Bool {
    NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
}

/// Plans a JSON file whose new content is computed from the local one (nil if missing).
func planJSONMerge(target: URL, kind: ItemKind, detail: String, merge: ([String: Any]?) throws -> Any) throws -> PlannedWrite {
    let local = readJSONObject(target)
    let merged = try merge(local)
    let data = try serializeJSON(merged)
    let action: PlannedWrite.Action = local == nil ? .create : jsonEqual(local!, merged) ? .unchanged : .update
    return PlannedWrite(target: target, data: data, kind: kind, action: action, detail: detail, modifiedAt: nil)
}

/// For JSON settings files with an `mcpServers` object: keeps this Mac's values, adds keys it
/// lacks, and merges MCP servers one by one (conflicts per `policy`).
func planSettingsMerge(_ data: Data, target: URL, policy: ConflictPolicy, notes: inout [RestoreNote]) throws -> PlannedWrite {
    let incoming = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    var conflicts: [RestoreNote] = []
    let write = try planJSONMerge(target: target, kind: .settings, detail: "merged settings and MCP servers") { local in
        var root = (local ?? [:]).merging(incoming) { local, _ in local }
        if let servers = incoming["mcpServers"] as? [String: Any] {
            root["mcpServers"] = mergeMCPServers(servers, into: local?["mcpServers"] as? [String: Any] ?? [:],
                                                 scope: nil, policy: policy, conflicts: &conflicts)
        }
        return root
    }
    notes += conflicts
    return write
}
