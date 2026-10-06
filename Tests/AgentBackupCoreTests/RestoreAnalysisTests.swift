import Foundation
import Testing
@testable import AgentBackupCore

struct RestoreAnalysisTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID().uuidString)")

    func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func item(_ project: String?) -> SnapshotItem {
        SnapshotItem(kind: .session, path: "s.jsonl", project: project.map { ProjectRef(dirName: "x", path: $0) },
                     blob: "b", size: 1, modifiedAt: nil)
    }

    @Test func findsMissingProjectsAndSuggestsMovedFolders() throws {
        try mkdir("Documents/kept")
        try mkdir("Code/moved")
        try mkdir("Code/work/deep")
        let manifest = Manifest(id: "id", createdAt: Date(), source: SourceInfo(hostname: "old", userName: "old", home: "/Users/old"), agents: [
            AgentSnapshot(agentID: "claude-code", items: [
                item("/Users/old/Documents/kept"), item("/Users/old/Documents/kept"),
                item("/Users/old/Documents/moved"), item("/Users/old/Documents/deep"),
                item("/Users/old/Documents/gone"), item(nil),
            ]),
        ])

        let projects = RestoreAnalysis.projects(in: manifest, targetHome: home)
        #expect(projects.map(\.name) == ["deep", "gone", "moved", "kept"])   // missing first
        let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0) })
        #expect(byName["kept"]?.existsAtDefault == true && byName["kept"]?.fileCount == 2)
        #expect(byName["moved"]?.defaultTarget == home.path + "/Documents/moved")
        #expect(byName["moved"]?.suggestions == [home.appendingPathComponent("Code/moved").standardizedFileURL.path])
        #expect(byName["deep"]?.suggestions == [home.appendingPathComponent("Code/work/deep").standardizedFileURL.path])
        #expect(byName["gone"]?.suggestions == [])
    }
}
