import Foundation

/// The undo record of one restore, in
/// `~/Library/Application Support/AgentBackup/rollback/<yyyyMMdd-HHmmss-SSS>/`:
/// ```
/// files/<path relative to home>   copies of the files the restore overwrote
/// created-files.txt               absolute paths of files the restore created
/// ```
public struct RollbackPoint: Identifiable, Equatable {
    public let url: URL
    public let date: Date

    public var id: String { url.lastPathComponent }

    static let createdList = "created-files.txt"
    static let filesDir = "files"

    public static func directory(home: URL) -> URL {
        appSupportDirectory(home: home).appendingPathComponent("rollback", isDirectory: true)
    }

    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static func create(home: URL, date: Date) throws -> RollbackPoint {
        var name = nameFormatter.string(from: date)
        var url = directory(home: home).appendingPathComponent(name, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            name = "\(nameFormatter.string(from: date))-\(suffix)"
            url = directory(home: home).appendingPathComponent(name, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RollbackPoint(url: url, date: date)
    }

    /// Newest first.
    public static func list(home: URL) -> [RollbackPoint] {
        let dir = directory(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard let date = nameFormatter.date(from: String(name.prefix(19))) else { return nil }
            return RollbackPoint(url: dir.appendingPathComponent(name, isDirectory: true), date: date)
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    func savedCopy(of target: URL, home: URL) -> URL {
        url.appendingPathComponent(Self.filesDir).appendingPathComponent(Self.relativePath(target, home: home))
    }

    func recordCreated(_ paths: [String]) throws {
        try Data(paths.map { $0 + "\n" }.joined().utf8).write(to: url.appendingPathComponent(Self.createdList), options: .atomic)
    }

    static func relativePath(_ target: URL, home: URL) -> String {
        let path = target.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : "_absolute" + path
    }

    /// What undoing this restore would do.
    public func plan(home: URL) -> (restore: [URL], delete: [URL]) {
        let filesRoot = url.appendingPathComponent(Self.filesDir)
        let restore = walkFiles(filesRoot).map { file in
            file.path.hasPrefix("_absolute/")
                ? URL(fileURLWithPath: String(file.path.dropFirst("_absolute".count)))
                : home.appendingPathComponent(file.path)
        }
        let listed = (try? String(contentsOf: url.appendingPathComponent(Self.createdList), encoding: .utf8)) ?? ""
        let delete = listed.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return (restore, delete)
    }

    /// Puts back every overwritten file, deletes every created file (and folders left empty),
    /// then removes this rollback point.
    @discardableResult
    public func undo(home: URL) throws -> (restored: Int, deleted: Int) {
        let fm = FileManager.default
        let filesRoot = url.appendingPathComponent(Self.filesDir)
        var restored = 0
        for file in walkFiles(filesRoot) {
            let target = file.path.hasPrefix("_absolute/")
                ? URL(fileURLWithPath: String(file.path.dropFirst("_absolute".count)))
                : home.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: file.url, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fm.copyItem(at: file.url, to: target)
            }
            restored += 1
        }

        var deleted = 0
        for target in plan(home: home).delete {
            try fm.removeItem(at: target)
            deleted += 1
            removeEmptyParents(of: target, stoppingAt: home)
        }
        try fm.removeItem(at: url)
        return (restored, deleted)
    }

    private func removeEmptyParents(of file: URL, stoppingAt home: URL) {
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let stop = home.standardizedFileURL.path
        while dir.path.hasPrefix(stop + "/"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              contents.allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }
}
