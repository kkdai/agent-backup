import Foundation

/// Daily automatic backups through a user LaunchAgent that runs the `agent-backup` CLI
/// (bundled inside the app). launchd runs missed jobs when the Mac wakes up.
public struct BackupSchedule {
    public static let label = "com.kkdai.agent-backup.scheduled"

    public struct Settings: Equatable {
        public var hour: Int
        public var minute: Int
        public var location: String

        public init(hour: Int = 3, minute: Int = 0, location: String = "gdrive") {
            self.hour = hour
            self.minute = minute
            self.location = location
        }
    }

    public let home: URL
    /// Runs `launchctl` with the given arguments; injectable for tests.
    let launchctl: ([String]) throws -> Void

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), launchctl: (([String]) throws -> Void)? = nil) {
        self.home = home
        self.launchctl = launchctl ?? Self.runLaunchctl
    }

    public var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    public var logURL: URL { home.appendingPathComponent("Library/Logs/AgentBackup/scheduled.log") }

    var domain: String { "gui/\(getuid())" }

    public func plist(executable: URL, settings: Settings) throws -> Data {
        let dict: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable.path, "backup", "--to", settings.location, "--prune", "--unattended"],
            "StartCalendarInterval": ["Hour": settings.hour, "Minute": settings.minute],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public func enable(executable: URL, settings: Settings) throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(executable: executable, settings: settings).write(to: plistURL, options: .atomic)
        try? launchctl(["bootout", "\(domain)/\(Self.label)"])   // fine if it wasn't loaded
        try launchctl(["bootstrap", domain, plistURL.path])
    }

    public func disable() throws {
        try? launchctl(["bootout", "\(domain)/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }

    /// The installed schedule, read back from the LaunchAgent plist.
    public var current: Settings? {
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let interval = dict["StartCalendarInterval"] as? [String: Int],
              let args = dict["ProgramArguments"] as? [String],
              let toIndex = args.firstIndex(of: "--to"), toIndex + 1 < args.count else { return nil }
        return Settings(hour: interval["Hour"] ?? 0, minute: interval["Minute"] ?? 0, location: args[toIndex + 1])
    }

    /// The last lines of the scheduled run's log.
    public func recentLog(lines: Int = 20) -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(lines).map(String.init))
    }

    static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ScheduleError.launchctl(arguments.first ?? "", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum ScheduleError: LocalizedError {
    case launchctl(String, String)
    public var errorDescription: String? {
        if case .launchctl(let command, let message) = self { "launchctl \(command) failed: \(message)" } else { nil }
    }
}
