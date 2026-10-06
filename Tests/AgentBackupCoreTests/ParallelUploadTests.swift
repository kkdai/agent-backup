import Foundation
import Testing
@testable import AgentBackupCore

struct ParallelUploadTests {
    func makeHome(files: Int, duplicate: Bool = false) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude/projects/-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data((duplicate ? "same content" : "session \(i)").utf8).write(to: dir.appendingPathComponent("s\(i).jsonl"))
        }
        return home
    }

    func backup(_ home: URL, to store: BackupStore, concurrency: Int = 6, progress: ((BackupProgress) -> Void)? = nil) async throws -> BackupResult {
        try await BackupEngine(store: store, vault: Vault(rawKey: Data(repeating: 9, count: 32))).backup(
            providers: Providers.all(home: home), source: SourceInfo(hostname: "mac", userName: "me", home: home.path),
            concurrency: concurrency, progress: progress)
    }

    @Test func uploadsRunConcurrentlyAndKeepOrder() async throws {
        let drive = FakeDrive()
        drive.latency = 20_000_000
        let home = try makeHome(files: 12)
        let result = try await backup(home, to: GoogleDriveStore(tokens: StaticTokens(), http: drive, sleep: { _ in }))

        #expect(drive.maxConcurrent > 1 && drive.maxConcurrent <= 6)
        #expect(result.newBlobCount == 12)
        let paths = try #require(result.manifest.agents.first?.items.map(\.path))
        #expect(paths == (0..<12).map { "s\($0).jsonl" }.sorted())   // same order as collected
    }

    @Test func identicalContentUploadsOnce() async throws {
        let drive = FakeDrive()
        drive.latency = 5_000_000
        let result = try await backup(try makeHome(files: 8, duplicate: true),
                                      to: GoogleDriveStore(tokens: StaticTokens(), http: drive, sleep: { _ in }))
        #expect(result.newBlobCount == 1)
        #expect(drive.names(in: "blobs").count == 1)
        #expect(Set(result.manifest.agents[0].items.map(\.blob)).count == 1)
    }

    @Test func progressCountsEveryFile() async throws {
        let store = LocalFolderStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("parallel-store-\(UUID().uuidString)"))
        let lock = NSLock()
        var updates: [BackupProgress] = []
        let result = try await backup(try makeHome(files: 10), to: store) { p in lock.withLock { updates.append(p) } }
        let final = try #require(lock.withLock { updates.max { $0.filesDone < $1.filesDone } })
        #expect(final.filesDone == 10 && final.filesTotal == 10)
        #expect(final.bytesUploaded == result.uploadedBytes && result.uploadedBytes > 0)
    }

    @Test func concurrentTokenRequestsShareOneRefresh() async throws {
        final class CountingServer: HTTPTransport {
            let lock = NSLock()
            var refreshes = 0
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lock.withLock { refreshes += 1 }
                try await Task.sleep(nanoseconds: 20_000_000)
                return (Data(#"{"access_token":"t","expires_in":3600}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let server = CountingServer()
        let secrets = MemorySecretStore()
        try secrets.set("google-refresh-token", Data("r".utf8))
        let auth = GoogleOAuth(client: GoogleClientConfig(clientID: "c", clientSecret: "s"), secrets: secrets, http: server)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await auth.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "t", count: 10))
        #expect(server.refreshes == 1)
    }
}
