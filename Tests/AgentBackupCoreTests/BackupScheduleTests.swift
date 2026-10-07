import Foundation
import Testing
@testable import AgentBackupCore

struct BackupScheduleTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-\(UUID().uuidString)")

    @Test func installsReadsBackAndRemovesTheLaunchAgent() throws {
        var calls: [[String]] = []
        let schedule = BackupSchedule(home: home) { calls.append($0) }
        let exe = URL(fileURLWithPath: "/Applications/Agent Backup.app/Contents/MacOS/agent-backup")
        #expect(schedule.current == nil)

        try schedule.enable(executable: exe, settings: .init(hour: 4, minute: 30))
        #expect(schedule.current == .init(hour: 4, minute: 30, location: "gdrive"))
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: schedule.plistURL), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [exe.path, "backup", "--to", "gdrive", "--prune", "--unattended"])
        #expect(plist["Label"] as? String == BackupSchedule.label)
        #expect(calls.map(\.first) == ["bootout", "bootstrap"])
        #expect(calls.last?.last == schedule.plistURL.path)

        try schedule.disable()
        #expect(schedule.current == nil)
        #expect(!FileManager.default.fileExists(atPath: schedule.plistURL.path))
        #expect(calls.last?.first == "bootout")
    }

    @Test func plistIsValidForLaunchd() throws {
        let schedule = BackupSchedule(home: home) { _ in }
        let url = home.appendingPathComponent("check.plist")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try schedule.plist(executable: URL(fileURLWithPath: "/bin/echo"), settings: .init()).write(to: url)
        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", url.path]
        lint.standardOutput = Pipe()
        try lint.run()
        lint.waitUntilExit()
        #expect(lint.terminationStatus == 0)
    }
}
