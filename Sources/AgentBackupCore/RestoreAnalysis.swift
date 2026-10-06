import Foundation

/// A project referenced by a snapshot, and where it should land on this Mac.
public struct ProjectMapping: Identifiable, Equatable {
    /// Absolute path on the source Mac.
    public let sourcePath: String
    /// Where the default home→home rule puts it.
    public let defaultTarget: String
    public let existsAtDefault: Bool
    /// Existing folders on this Mac with the same name, best first.
    public let suggestions: [String]
    /// How many snapshot files belong to this project.
    public let fileCount: Int

    public var id: String { sourcePath }
    public var name: String { (sourcePath as NSString).lastPathComponent }
}

public enum RestoreAnalysis {
    /// Every project in the snapshot with a recoverable path, missing ones first.
    public static func projects(in manifest: Manifest, targetHome: URL) -> [ProjectMapping] {
        let mapper = PathMapper(rules: [.init(from: manifest.source.home, to: targetHome.path)])
        var counts: [String: Int] = [:]
        for item in manifest.agents.flatMap(\.items) {
            if let path = item.project?.path { counts[path, default: 0] += 1 }
        }
        return counts.keys.map { source in
            let target = mapper.map(path: source)
            let exists = FileManager.default.fileExists(atPath: target)
            return ProjectMapping(
                sourcePath: source, defaultTarget: target, existsAtDefault: exists,
                suggestions: exists ? [] : suggestLocations(named: (source as NSString).lastPathComponent, home: targetHome, excluding: target),
                fileCount: counts[source] ?? 0
            )
        }
        .sorted { ($0.existsAtDefault ? 1 : 0, $0.sourcePath) < ($1.existsAtDefault ? 1 : 0, $1.sourcePath) }
    }

    /// Common places people keep code, searched two levels deep.
    static let searchRoots = ["Documents", "Code", "code", "Projects", "projects", "Developer", "src", "workspace", "git", "repos", "GitHub", "Desktop", ""]

    public static func suggestLocations(named name: String, home: URL, excluding: String? = nil) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()

        func consider(_ url: URL) {
            var isDir: ObjCBool = false
            let path = url.standardizedFileURL.path
            guard path != excluding, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(path.lowercased()).inserted else { return }
            found.append(path)
        }

        for rootName in searchRoots {
            let root = rootName.isEmpty ? home : home.appendingPathComponent(rootName)
            consider(root.appendingPathComponent(name))
            guard let children = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for child in children where !child.hasPrefix(".") && child != "Library" {
                consider(root.appendingPathComponent(child).appendingPathComponent(name))
            }
        }
        return Array(found.prefix(5))
    }
}
