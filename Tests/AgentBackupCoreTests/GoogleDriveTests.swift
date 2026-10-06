import Foundation
import Testing
@testable import AgentBackupCore

struct GoogleDriveStoreTests {
    let drive = FakeDrive()
    let tokens = StaticTokens()

    func makeStore(multipartLimit: Int = 5 << 20) -> GoogleDriveStore {
        GoogleDriveStore(tokens: tokens, http: drive, multipartLimit: multipartLimit, sleep: { _ in })
    }

    @Test func createsFolderLayoutOnceAndReusesIt() async throws {
        try await makeStore().putKeyfile(Data("{}"))
        // A second Mac (fresh store instance) finds the same folders instead of creating new ones.
        #expect(try await makeStore().keyfile() == Data("{}"))
        #expect(drive.files.values.filter { $0.name == "AgentBackup" }.count == 1)
        #expect(drive.names(in: "AgentBackup") == ["blobs", "keyfile.json", "snapshots"])
    }

    @Test func refusesToReplaceKeyfile() async throws {
        let store = makeStore()
        try await store.putKeyfile(Data("{}"))
        await #expect(throws: DriveError.self) { try await store.putKeyfile(Data("{}")) }
    }

    @Test func storesBlobsAndSnapshotsWithPagination() async throws {
        let store = makeStore(multipartLimit: 10)
        for i in 0..<5 { try await store.putBlob("blob\(i)", Data("content \(i) is longer than ten bytes")) }
        try await store.putBlob("tiny", Data("small"))
        try await store.putSnapshot("20261006-000000-mac", Data("manifest"))

        let fresh = makeStore()
        #expect(try await fresh.blobIDs() == Set((0..<5).map { "blob\($0)" } + ["tiny"]))
        #expect(try await fresh.blob("blob3") == Data("content 3 is longer than ten bytes"))
        #expect(try await fresh.blob("tiny") == Data("small"))
        #expect(try await fresh.snapshotIDs() == ["20261006-000000-mac"])
        #expect(drive.requests.contains("PUT /upload/session/s0"))
        #expect(drive.requests.filter { $0 == "GET /drive/v3/files" }.count >= 3)
    }

    @Test func retriesRateLimitsAndRefreshesExpiredTokens() async throws {
        let store = makeStore()
        drive.injectedFailures = [429, 503]
        try await store.putBlob("a", Data("x"))

        drive.expectedToken = "token-2"
        tokens.token = "token-1"
        let refreshing = makeStore()
        await #expect(throws: DriveError.self) { try await refreshing.blob("a") }
        #expect(tokens.invalidations == 1)
    }

    @Test func fullBackupAndRestoreThroughDrive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-e2e-\(UUID().uuidString)")
        let oldHome = root.appendingPathComponent("old/me"), newHome = root.appendingPathComponent("new/me")
        let session = oldHome.appendingPathComponent(".claude/projects/\(PathMapper.claudeProjectDirName(for: oldHome.path + "/p"))/s.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cwd":"\#(oldHome.path)/p"}"# + "\n").write(to: session)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)

        let (vault, _) = try await BackupEngine.initialize(makeStore(), passphrase: "passphrase", iterations: 1000)
        _ = try await BackupEngine(store: makeStore(), vault: vault).backup(
            providers: Providers.all(home: oldHome), source: SourceInfo(hostname: "old", userName: "me", home: oldHome.path))

        // New Mac: only the passphrase and the Drive.
        let store = makeStore()
        let unlocked = try Vault.unlock(try #require(try await BackupEngine.keyfile(in: store)), passphrase: "passphrase")
        let engine = BackupEngine(store: store, vault: unlocked)
        let plans = try await engine.planRestore(manifest: try await engine.manifest(id: nil), targetHome: newHome)
        _ = try BackupEngine.apply(plans, home: newHome)

        let restored = newHome.appendingPathComponent(".claude/projects/\(PathMapper.claudeProjectDirName(for: newHome.path + "/p"))/s.jsonl")
        #expect(try String(contentsOf: restored, encoding: .utf8).contains(newHome.path + "/p"))
        #expect(!drive.files.values.contains { String(decoding: $0.data, as: UTF8.self).contains("cwd") })
    }

    @Test func escapesQueryValues() {
        #expect(GoogleDriveStore.quoted("it's") == #"'it\'s'"#)
    }
}

struct GoogleOAuthTests {
    /// Fake token endpoint.
    final class TokenServer: HTTPTransport {
        var forms: [[String: String]] = []
        var refreshResponse: (Int, String) = (200, #"{"access_token":"refreshed","expires_in":3600}"#)

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let form = Dictionary(uniqueKeysWithValues: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                .split(separator: "&").map { pair -> (String, String) in
                    let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                    return (kv[0], kv.count > 1 ? kv[1] : "")
                })
            forms.append(form)
            let (status, body) = form["grant_type"] == "authorization_code"
                ? (200, #"{"access_token":"first","refresh_token":"refresh-1","expires_in":3600}"#)
                : refreshResponse
            return (Data(body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    let client = GoogleClientConfig(clientID: "id.apps.googleusercontent.com", clientSecret: "s")

    @Test func parsesCloudConsoleJSON() throws {
        let json = #"{"installed":{"client_id":"abc","client_secret":"def","redirect_uris":["http://localhost"]}}"#
        #expect(try GoogleClientConfig.parse(googleJSON: Data(json)) == GoogleClientConfig(clientID: "abc", clientSecret: "def"))
        #expect(throws: GoogleAuthError.badClientConfig) { try GoogleClientConfig.parse(googleJSON: Data(#"{"web":{}}"#)) }
    }

    @Test func loopbackLoginWithPKCE() async throws {
        let server = TokenServer()
        let secrets = MemorySecretStore()
        let auth = GoogleOAuth(client: client, secrets: secrets, http: server)

        try await auth.login { url in
            // Play the browser: Google redirects back to the loopback address with a code.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let value = { (n: String) in items.first { $0.name == n }!.value! }
            #expect(value("scope") == GoogleOAuth.scope)
            #expect(value("code_challenge_method") == "S256")
            let callback = URL(string: "\(value("redirect_uri"))/?code=the-code&state=\(value("state"))")!
            Task { _ = try await URLSession.shared.data(from: callback) }
        }

        #expect(secrets.get("google-refresh-token") == Data("refresh-1"))
        let exchange = try #require(server.forms.first)
        #expect(exchange["code"] == "the-code" && exchange["code_verifier"]?.count ?? 0 >= 43)
        #expect(try await auth.accessToken() == "first")
        auth.invalidate()
        #expect(try await auth.accessToken() == "refreshed")
    }

    @Test func rejectsForgedState() async throws {
        let auth = GoogleOAuth(client: client, secrets: MemorySecretStore(), http: TokenServer())
        await #expect(throws: GoogleAuthError.loginFailed("state mismatch")) {
            try await auth.login { url in
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
                Task { _ = try await URLSession.shared.data(from: URL(string: "\(redirect)/?code=x&state=forged")!) }
            }
        }
    }

    @Test func revokedRefreshTokenLogsOut() async throws {
        let server = TokenServer()
        server.refreshResponse = (400, #"{"error":"invalid_grant"}"#)
        let secrets = MemorySecretStore()
        try secrets.set("google-refresh-token", Data("old"))
        let auth = GoogleOAuth(client: client, secrets: secrets, http: server)
        await #expect(throws: GoogleAuthError.notLoggedIn) { try await auth.accessToken() }
        #expect(!auth.isLoggedIn)
    }
}
