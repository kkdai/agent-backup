import Foundation

public enum DriveError: LocalizedError, Equatable {
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body): "Google Drive request failed (\(status)): \(body)"
        case .badResponse(let what): "Unexpected Google Drive response: \(what)"
        }
    }
}

/// `My Drive/AgentBackup/` via the Drive v3 REST API, using the `drive.file` scope.
///
/// `drive.file` means the app sees only files it created itself — but that's per OAuth
/// client, not per device, so a second Mac running the same app sees the same backup.
public final class GoogleDriveStore: BackupStore {
    static let api = "https://www.googleapis.com/drive/v3/files"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3/files"
    static let folderType = "application/vnd.google-apps.folder"

    let tokens: AccessTokenProvider
    let http: HTTPTransport
    let rootName: String
    /// Above this size uploads use a resumable session instead of one multipart request.
    let multipartLimit: Int
    let sleep: (Double) async -> Void

    private var folderIDs: (root: String, blobs: String, snapshots: String)?
    struct DriveFile {
        var id: String
        var created: Date
        var size: Int
    }

    private var blobFiles: [String: DriveFile]?
    private var snapshotFiles: [String: DriveFile]?

    public init(
        tokens: AccessTokenProvider, http: HTTPTransport = URLSessionTransport(), rootName: String = "AgentBackup",
        multipartLimit: Int = 5 << 20,
        sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.tokens = tokens
        self.http = http
        self.rootName = rootName
        self.multipartLimit = multipartLimit
        self.sleep = sleep
    }

    public var displayName: String { "Google Drive › \(rootName)" }

    // MARK: - BackupStore

    public func keyfile() async throws -> Data? {
        let root = try await folders().root
        guard let id = try await find(name: "keyfile.json", parent: root) else { return nil }
        return try await download(id)
    }

    public func putKeyfile(_ data: Data) async throws {
        let root = try await folders().root
        // Never silently replace a keyfile: that would lock the user out of every existing snapshot.
        guard try await find(name: "keyfile.json", parent: root) == nil else {
            throw DriveError.badResponse("keyfile.json already exists")
        }
        _ = try await upload(name: "keyfile.json", parent: root, data: data, mimeType: "application/json")
    }

    public func replaceKeyfile(_ data: Data) async throws {
        let root = try await folders().root
        guard let id = try await find(name: "keyfile.json", parent: root) else { throw BackupError.notInitialized }
        // Updating content in place keeps the file ID; Drive applies it atomically.
        var request = URLRequest(url: URL(string: "\(Self.uploadAPI)/\(id)?uploadType=media&fields=id")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request)
    }

    public func blobIDs() async throws -> Set<String> {
        Set(try await blobIndex().keys)
    }

    public func blobInfo() async throws -> [BlobInfo] {
        try await blobIndex().map { BlobInfo(id: $0.key, created: $0.value.created, size: $0.value.size) }
    }

    public func putBlob(_ id: String, _ data: Data) async throws {
        let fileID = try await upload(name: id, parent: try await folders().blobs, data: data)
        blobFiles?[id] = DriveFile(id: fileID, created: Date(), size: data.count)
    }

    public func blob(_ id: String) async throws -> Data {
        guard let file = try await blobIndex()[id] else { throw DriveError.badResponse("blob \(id) is missing") }
        return try await download(file.id)
    }

    public func deleteBlob(_ id: String) async throws {
        guard let file = try await blobIndex()[id] else { return }
        try await delete(file.id)
        blobFiles?[id] = nil
    }

    public func snapshotIDs() async throws -> [String] {
        Array(try await snapshotIndex().keys)
    }

    public func putSnapshot(_ id: String, _ data: Data) async throws {
        let fileID = try await upload(name: id, parent: try await folders().snapshots, data: data)
        snapshotFiles?[id] = DriveFile(id: fileID, created: Date(), size: data.count)
    }

    public func snapshot(_ id: String) async throws -> Data {
        guard let file = try await snapshotIndex()[id] else { throw BackupError.snapshotNotFound(id) }
        return try await download(file.id)
    }

    public func deleteSnapshot(_ id: String) async throws {
        guard let file = try await snapshotIndex()[id] else { throw BackupError.snapshotNotFound(id) }
        try await delete(file.id)
        snapshotFiles?[id] = nil
    }

    public struct Account {
        public var email: String?
        public var displayName: String?
        public var usedBytes: Int64?
        public var limitBytes: Int64?
    }

    /// The signed-in Google account and storage quota.
    public func account() async throws -> Account {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [.init(name: "fields", value: "user(displayName,emailAddress),storageQuota(usage,limit)")]
        let json = try await send(URLRequest(url: components.url!))
        let user = json["user"] as? [String: Any]
        let quota = json["storageQuota"] as? [String: Any]
        return Account(
            email: user?["emailAddress"] as? String, displayName: user?["displayName"] as? String,
            usedBytes: (quota?["usage"] as? String).flatMap { Int64($0) },
            limitBytes: (quota?["limit"] as? String).flatMap { Int64($0) }
        )
    }

    // MARK: - Folders & indexes

    private func folders() async throws -> (root: String, blobs: String, snapshots: String) {
        if let folderIDs { return folderIDs }
        let root = try await findOrCreateFolder(rootName, parent: "root")
        let ids = (root, try await findOrCreateFolder("blobs", parent: root), try await findOrCreateFolder("snapshots", parent: root))
        folderIDs = ids
        return ids
    }

    private func blobIndex() async throws -> [String: DriveFile] {
        if let blobFiles { return blobFiles }
        let index = try await list(parent: try await folders().blobs)
        blobFiles = index
        return index
    }

    private func snapshotIndex() async throws -> [String: DriveFile] {
        if let snapshotFiles { return snapshotFiles }
        let index = try await list(parent: try await folders().snapshots)
        snapshotFiles = index
        return index
    }

    private func findOrCreateFolder(_ name: String, parent: String) async throws -> String {
        if let id = try await find(name: name, parent: parent, mimeType: Self.folderType) { return id }
        var request = URLRequest(url: URL(string: "\(Self.api)?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderType, "parents": [parent]])
        return try fileID(from: try await send(request))
    }

    // MARK: - Drive calls

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func find(name: String, parent: String, mimeType: String? = nil) async throws -> String? {
        var q = "name = \(Self.quoted(name)) and \(Self.quoted(parent)) in parents and trashed = false"
        if let mimeType { q += " and mimeType = \(Self.quoted(mimeType))" }
        var components = URLComponents(string: Self.api)!
        // Oldest first, so if two Macs raced to create the folder both settle on the same one.
        components.queryItems = [.init(name: "q", value: q), .init(name: "orderBy", value: "createdTime"),
                                 .init(name: "fields", value: "files(id)"), .init(name: "spaces", value: "drive")]
        let json = try await send(URLRequest(url: components.url!))
        return ((json["files"] as? [[String: Any]])?.first)?["id"] as? String
    }

    /// name → file for every file directly in `parent`.
    private func list(parent: String) async throws -> [String: DriveFile] {
        var out: [String: DriveFile] = [:]
        var pageToken: String?
        repeat {
            var components = URLComponents(string: Self.api)!
            components.queryItems = [
                .init(name: "q", value: "\(Self.quoted(parent)) in parents and trashed = false"),
                .init(name: "fields", value: "nextPageToken,files(id,name,createdTime,size)"),
                .init(name: "pageSize", value: "1000"), .init(name: "spaces", value: "drive"),
            ] + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let json = try await send(URLRequest(url: components.url!))
            for file in json["files"] as? [[String: Any]] ?? [] {
                guard let name = file["name"] as? String, let id = file["id"] as? String else { continue }
                let created = (file["createdTime"] as? String).flatMap(Self.parseDate) ?? .distantPast
                out[name] = DriveFile(id: id, created: created, size: (file["size"] as? String).flatMap { Int($0) } ?? 0)
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    private func upload(name: String, parent: String, data: Data, mimeType: String = "application/octet-stream") async throws -> String {
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        if data.count <= multipartLimit {
            let boundary = "agent-backup-\(UUID().uuidString)"
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body += metadata
            body += Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
            body += data
            body += Data("\r\n--\(boundary)--\r\n".utf8)
            var request = URLRequest(url: URL(string: "\(Self.uploadAPI)?uploadType=multipart&fields=id")!)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return try fileID(from: try await send(request))
        }

        var start = URLRequest(url: URL(string: "\(Self.uploadAPI)?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = metadata
        let (_, response) = try await sendRaw(start)
        guard let location = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw DriveError.badResponse("resumable upload returned no session URL")
        }
        var put = URLRequest(url: location)
        put.httpMethod = "PUT"
        put.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        put.httpBody = data
        return try fileID(from: try await send(put))
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func delete(_ fileID: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/\(fileID)")!)
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    private func download(_ fileID: String) async throws -> Data {
        try await sendRaw(URLRequest(url: URL(string: "\(Self.api)/\(fileID)?alt=media")!)).0
    }

    private func fileID(from json: [String: Any]) throws -> String {
        guard let id = json["id"] as? String else { throw DriveError.badResponse("no file id") }
        return id
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await sendRaw(request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Adds auth; retries rate limits and 5xx with exponential backoff, and a 401 once with a fresh token.
    private func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var refreshedToken = false
        var attempt = 0
        while true {
            var authed = request
            authed.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.send(authed)
            let status = response.statusCode
            if (200..<300).contains(status) { return (data, response) }

            let body = String(decoding: data.prefix(500), as: UTF8.self)
            if status == 401 && !refreshedToken {
                refreshedToken = true
                tokens.invalidate()
                continue
            }
            let rateLimited = status == 429 || (status == 403 && body.contains("ateLimitExceeded"))
            if (rateLimited || (500...599).contains(status)) && attempt < 5 {
                await sleep(pow(2, Double(attempt)) + Double.random(in: 0..<1))
                attempt += 1
                continue
            }
            throw DriveError.http(status, body)
        }
    }
}
