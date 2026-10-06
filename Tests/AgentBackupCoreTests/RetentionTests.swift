import Foundation
import Testing
@testable import AgentBackupCore

struct RetentionTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC

    func id(daysAgo: Double, hour: Double = 12, host: String = "mac") -> String {
        BackupEngine.snapshotID(date: start.addingTimeInterval(400 * 86400 - daysAgo * 86400 + hour * 3600), hostname: host)
    }

    @Test func keepsLastDailyWeeklyMonthly() {
        // Three backups a day for 100 days.
        let ids = (0..<100).flatMap { day in [8.0, 12, 20].map { id(daysAgo: Double(day), hour: $0) } }
        let policy = RetentionPolicy(keepLast: 2, keepDaily: 3, keepWeekly: 2, keepMonthly: 3)
        let keep = policy.keep(ids, calendar: utc)

        #expect(keep.contains(id(daysAgo: 0, hour: 20)) && keep.contains(id(daysAgo: 0, hour: 12)))  // last 2
        #expect(keep.contains(id(daysAgo: 1, hour: 20)) && keep.contains(id(daysAgo: 2, hour: 20)))  // daily
        #expect(!keep.contains(id(daysAgo: 1, hour: 8)))
        #expect(keep.count <= 2 + 3 + 2 + 3)
        #expect(keep.count >= 5)
    }

    @Test func eachMacKeepsItsOwnHistory() {
        let ids = (0..<20).map { id(daysAgo: Double($0), host: "busy") } + [id(daysAgo: 50, host: "old")]
        let keep = RetentionPolicy(keepLast: 1, keepDaily: 0, keepWeekly: 0, keepMonthly: 0).keep(ids, calendar: utc)
        #expect(keep == [id(daysAgo: 0, host: "busy"), id(daysAgo: 50, host: "old")])
    }

    @Test func unparseableIDsAreKept() {
        #expect(RetentionPolicy(keepLast: 1).keep(["weird"], calendar: utc) == ["weird"])
    }

    func prunesThroughStore(_ store: BackupStore) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let engine = BackupEngine(store: store, vault: Vault(rawKey: Data(repeating: 3, count: 32)))
        let source = SourceInfo(hostname: "mac", userName: "me", home: home.path)

        // Three snapshots, each with a different settings.json.
        for (i, day) in [3.0, 2, 1].enumerated() {
            try Data(#"{"v":\#(i)}"#.utf8).write(to: settings)
            _ = try await engine.backup(providers: Providers.all(home: home), source: source,
                                        now: start.addingTimeInterval(day * -86400))
        }
        #expect(try await store.blobIDs().count == 3)

        let policy = RetentionPolicy(keepLast: 1, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        // Blobs were just uploaded: within the grace period nothing is deleted yet.
        let young = try await engine.planPrune(policy: policy, now: Date(), calendar: utc)
        #expect(young.deletedSnapshots.count == 2 && young.deletedBlobs.isEmpty && young.youngUnreferencedBlobs == 2)

        let plan = try await engine.planPrune(policy: policy, now: Date().addingTimeInterval(2 * 86400), calendar: utc)
        #expect(plan.deletedBlobs.count == 2 && plan.freedBytes > 0)
        try await engine.prune(plan)

        #expect(try await store.snapshotIDs().count == 1)
        #expect(try await store.blobIDs().count == 1)
        // The kept snapshot still restores.
        let kept = try await engine.manifest(id: nil)
        let blob = try #require(kept.agents.first?.items.first?.blob)
        #expect(try engine.vault.open(try await store.blob(blob), expectedID: blob) == Data(#"{"v":2}"#.utf8))
    }

    @Test func prunesLocalFolder() async throws {
        try await prunesThroughStore(LocalFolderStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("prune-store-\(UUID().uuidString)")))
    }

    @Test func prunesGoogleDrive() async throws {
        try await prunesThroughStore(GoogleDriveStore(tokens: StaticTokens(), http: FakeDrive(), sleep: { _ in }))
    }
}
