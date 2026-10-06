import Foundation

/// Which snapshots to keep, applied separately to each Mac's snapshots.
/// A snapshot is kept if any rule selects it (like `restic forget`).
public struct RetentionPolicy: Equatable {
    public var keepLast: Int
    /// The newest snapshot of each of the last N days that have one.
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int

    public init(keepLast: Int = 5, keepDaily: Int = 7, keepWeekly: Int = 4, keepMonthly: Int = 12) {
        self.keepLast = max(1, keepLast)
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
    }

    public static let standard = RetentionPolicy()

    /// The snapshot IDs to keep. Works on IDs alone (they carry time and device), no decryption needed.
    /// Unparseable IDs are always kept.
    public func keep(_ ids: [String], calendar: Calendar = .current) -> Set<String> {
        var keep = Set<String>()
        var byHost: [String: [(id: String, date: Date)]] = [:]
        for id in ids {
            guard let parsed = BackupEngine.parseSnapshotID(id) else {
                keep.insert(id)
                continue
            }
            byHost[parsed.hostname, default: []].append((id, parsed.date))
        }

        for snapshots in byHost.values {
            let newestFirst = snapshots.sorted { $0.date > $1.date }
            newestFirst.prefix(keepLast).forEach { keep.insert($0.id) }

            func keepNewest(per components: Set<Calendar.Component>, count: Int) {
                var buckets = Set<DateComponents>()
                for snapshot in newestFirst {
                    guard buckets.count < count else { return }
                    if buckets.insert(calendar.dateComponents(components, from: snapshot.date)).inserted {
                        keep.insert(snapshot.id)
                    }
                }
            }
            keepNewest(per: [.year, .month, .day], count: keepDaily)
            keepNewest(per: [.yearForWeekOfYear, .weekOfYear], count: keepWeekly)
            keepNewest(per: [.year, .month], count: keepMonthly)
        }
        return keep
    }
}

public struct PrunePlan {
    public var keptSnapshots: [String]
    public var deletedSnapshots: [String]
    /// Unreferenced by any kept snapshot and older than the grace period.
    public var deletedBlobs: [BlobInfo]
    /// Unreferenced but recent: possibly still being uploaded by another Mac's backup.
    public var youngUnreferencedBlobs: Int

    public var freedBytes: Int { deletedBlobs.reduce(0) { $0 + $1.size } }
}

extension BackupEngine {
    /// What `prune` would delete. Decrypts the snapshots that are kept, to know which blobs they use.
    public func planPrune(
        policy: RetentionPolicy = .standard, now: Date = Date(),
        blobGracePeriod: TimeInterval = 24 * 3600, calendar: Calendar = .current
    ) async throws -> PrunePlan {
        let ids = try await store.snapshotIDs()
        let keep = policy.keep(ids, calendar: calendar)
        var referenced = Set<String>()
        for id in keep {
            for agent in try await manifest(id: id).agents {
                for item in agent.items { referenced.insert(item.blob) }
            }
        }
        let unreferenced = try await store.blobInfo().filter { !referenced.contains($0.id) }
        let old = unreferenced.filter { now.timeIntervalSince($0.created) >= blobGracePeriod }
        return PrunePlan(
            keptSnapshots: ids.filter(keep.contains).sorted(by: >),
            deletedSnapshots: ids.filter { !keep.contains($0) }.sorted(by: >),
            deletedBlobs: old.sorted { $0.id < $1.id },
            youngUnreferencedBlobs: unreferenced.count - old.count
        )
    }

    /// Deletes snapshots first, then blobs, so an interruption never leaves a snapshot with missing blobs.
    public func prune(_ plan: PrunePlan) async throws {
        for id in plan.deletedSnapshots { try await store.deleteSnapshot(id) }
        for blob in plan.deletedBlobs { try await store.deleteBlob(blob.id) }
    }
}
