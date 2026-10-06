import Foundation
import Testing
@testable import AgentBackupCore

struct RollbackTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString)")

    func write(_ text: String, _ path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    func plan(_ writes: [(String, String)]) -> [RestorePlan] {
        var plan = RestorePlan(agentID: "test")
        plan.writes = writes.map { path, text in
            let target = home.appendingPathComponent(path)
            let action: PlannedWrite.Action = FileManager.default.fileExists(atPath: target.path) ? .update : .create
            return PlannedWrite(target: target, data: Data(text.utf8), kind: .settings, action: action, detail: nil, modifiedAt: nil)
        }
        return [plan]
    }

    @Test func undoRestoresOverwrittenAndDeletesCreated() throws {
        try write("original", ".claude/settings.json")
        let result = try BackupEngine.apply(plan([
            (".claude/settings.json", "restored"),
            (".claude/projects/-new/s.jsonl", "session"),
        ]), home: home)
        #expect(read(".claude/settings.json") == "restored")

        let point = try #require(RollbackPoint.list(home: home).first)
        #expect(point.url == result.rollbackDir)
        let preview = point.plan(home: home)
        #expect(preview.restore.map(\.lastPathComponent) == ["settings.json"])
        #expect(preview.delete.map(\.lastPathComponent) == ["s.jsonl"])

        let undone = try point.undo(home: home)
        #expect(undone.restored == 1 && undone.deleted == 1)
        #expect(read(".claude/settings.json") == "original")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects/-new").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects").path) == false)
        #expect(RollbackPoint.list(home: home).isEmpty)
    }

    @Test func restoresInTheSameSecondGetSeparatePoints() throws {
        let now = Date()
        _ = try BackupEngine.apply(plan([("a.txt", "1")]), home: home, now: now)
        _ = try BackupEngine.apply(plan([("a.txt", "2")]), home: home, now: now)
        let points = RollbackPoint.list(home: home)
        #expect(points.count == 2)

        // Undo newest first: back to "1", then to nothing.
        try points[0].undo(home: home)
        #expect(read("a.txt") == "1")
        try points[1].undo(home: home)
        #expect(read("a.txt") == nil)
    }

    @Test func nothingWrittenMeansNoRollbackPoint() throws {
        #expect(try BackupEngine.apply([RestorePlan(agentID: "x")], home: home).rollbackDir == nil)
        #expect(RollbackPoint.list(home: home).isEmpty)
    }
}
