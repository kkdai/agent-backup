import Foundation
import Testing
@testable import AgentBackupCore

struct ResumableUploadTests {
    let drive = FakeDrive()
    let payload = Data((0..<100).map { UInt8($0) })

    /// Everything over 10 bytes goes resumable, in 16-byte chunks.
    func store() -> GoogleDriveStore {
        GoogleDriveStore(tokens: StaticTokens(), http: drive, multipartLimit: 10, chunkSize: 16, sleep: { _ in })
    }

    func storedBlob() -> Data? { drive.files.values.first { $0.name == "big" }?.data }
    func count(_ request: String) -> Int { drive.requests.filter { $0 == request }.count }

    @Test func uploadsInChunks() async throws {
        try await store().putBlob("big", payload)
        #expect(storedBlob() == payload)
        #expect(count("PUT /upload/session/s0") == 7)   // ceil(100 / 16)
    }

    @Test func resumesFromWhatDriveReceived() async throws {
        drive.failChunks = 2   // each failure keeps half the chunk, then 503
        try await store().putBlob("big", payload)
        #expect(storedBlob() == payload)
        #expect(count("POST /upload/drive/v3/files") == 1)   // same session, never restarted
    }

    @Test func restartsWhenTheSessionExpires() async throws {
        drive.expireNextSession = true
        try await store().putBlob("big", payload)
        #expect(storedBlob() == payload)
        #expect(count("POST /upload/drive/v3/files") == 2)
    }

    @Test func givesUpAfterRepeatedFailuresWithoutProgress() async throws {
        drive.failChunks = 1000
        let tiny = GoogleDriveStore(tokens: StaticTokens(), http: drive, multipartLimit: 0, chunkSize: 1, sleep: { _ in })
        await #expect(throws: DriveError.self) { try await tiny.putBlob("big", Data([1])) }
    }
}
