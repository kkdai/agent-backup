import Foundation
@testable import AgentBackupCore

/// In-memory stand-in for the handful of Drive v3 endpoints `GoogleDriveStore` uses.
/// Pages list results two at a time so pagination is exercised.
final class FakeDrive: HTTPTransport {
    struct File {
        var id: String
        var name: String
        var parent: String
        var mimeType: String
        var data: Data
        var created = Date()
    }

    var files: [String: File] = [:]
    var requests: [String] = []
    /// Status codes to return (once each) before handling requests normally.
    var injectedFailures: [Int] = []
    var expectedToken = "token-1"
    private var nextID = 0
    private var sessions: [String: (name: String, parent: String)] = [:]

    private let lock = NSLock()
    /// Highest number of requests in flight at once, to check uploads run in parallel.
    private(set) var maxConcurrent = 0
    private var inFlight = 0
    var latency: UInt64 = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { inFlight += 1; maxConcurrent = max(maxConcurrent, inFlight) }
        if latency > 0 { try await Task.sleep(nanoseconds: latency) }
        defer { lock.withLock { inFlight -= 1 } }
        return try lock.withLock { try handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        requests.append("\(method) \(url.path)")
        if !injectedFailures.isEmpty { return respond(injectedFailures.removeFirst(), json: ["error": "injected"]) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedToken)" else {
            return respond(401, json: ["error": "unauthenticated"])
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        switch (method, url.path) {
        case ("GET", "/drive/v3/files"):
            return list(q: query["q"] ?? "", pageToken: query["pageToken"])
        case ("POST", "/drive/v3/files"):
            let meta = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            return respond(200, json: ["id": create(meta, data: Data())])
        case ("POST", "/upload/drive/v3/files") where query["uploadType"] == "multipart":
            let (meta, data) = parseMultipart(request)
            return respond(200, json: ["id": create(meta, data: data)])
        case ("POST", "/upload/drive/v3/files") where query["uploadType"] == "resumable":
            let meta = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            let session = "s\(sessions.count)"
            sessions[session] = (meta["name"] as! String, (meta["parents"] as! [String])[0])
            return respond(200, json: [:], headers: ["Location": "https://www.googleapis.com/upload/session/\(session)"])
        case ("PUT", let path) where path.hasPrefix("/upload/session/"):
            let session = sessions[url.lastPathComponent]!
            return respond(200, json: ["id": create(["name": session.name, "parents": [session.parent]], data: request.httpBody ?? Data())])
        case ("PATCH", let path) where path.hasPrefix("/upload/drive/v3/files/") && query["uploadType"] == "media":
            guard files[url.lastPathComponent] != nil else { return respond(404, json: [:]) }
            files[url.lastPathComponent]!.data = request.httpBody ?? Data()
            return respond(200, json: ["id": url.lastPathComponent])
        case ("DELETE", let path) where path.hasPrefix("/drive/v3/files/"):
            guard files.removeValue(forKey: url.lastPathComponent) != nil else { return respond(404, json: [:]) }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        case ("GET", let path) where path.hasPrefix("/drive/v3/files/") && query["alt"] == "media":
            guard let file = files[url.lastPathComponent] else { return respond(404, json: [:]) }
            return (file.data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        default:
            return respond(400, json: ["error": "unsupported \(method) \(url.path)"])
        }
    }

    func names(in parentName: String) -> [String] {
        guard let parent = files.values.first(where: { $0.name == parentName }) else { return [] }
        return files.values.filter { $0.parent == parent.id }.map(\.name).sorted()
    }

    private func create(_ meta: [String: Any], data: Data) -> String {
        nextID += 1
        let id = "f\(nextID)"
        files[id] = File(id: id, name: meta["name"] as! String, parent: (meta["parents"] as! [String])[0],
                         mimeType: meta["mimeType"] as? String ?? "application/octet-stream", data: data)
        return id
    }

    /// Understands exactly the clauses the store sends: name, parent, mimeType, trashed.
    private func list(q: String, pageToken: String?) -> (Data, HTTPURLResponse) {
        func capture(_ pattern: String) -> String? {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) else { return nil }
            return String(q[Range(m.range(at: 1), in: q)!]).replacingOccurrences(of: "\\'", with: "'")
        }
        let name = capture(#"name = '((?:[^'\\]|\\.)*)'"#)
        let parent = capture(#"'([^']*)' in parents"#)
        let mime = capture(#"mimeType = '([^']*)'"#)
        let matches = files.values
            .filter { f in (name == nil || f.name == name) && (parent == nil || f.parent == parent) && (mime == nil || f.mimeType == mime) }
            .sorted { Int($0.id.dropFirst())! < Int($1.id.dropFirst())! }
        let start = Int(pageToken ?? "0")!
        let page = matches.dropFirst(start).prefix(2)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var json: [String: Any] = ["files": page.map {
            ["id": $0.id, "name": $0.name, "createdTime": iso.string(from: $0.created), "size": String($0.data.count)]
        }]
        if start + 2 < matches.count { json["nextPageToken"] = String(start + 2) }
        return respond(200, json: json)
    }

    private func parseMultipart(_ request: URLRequest) -> ([String: Any], Data) {
        let contentType = request.value(forHTTPHeaderField: "Content-Type")!
        let boundary = Data("--" + contentType.components(separatedBy: "boundary=")[1])
        let body = request.httpBody!
        var parts: [Data] = []
        var cursor = body.startIndex
        while let range = body.range(of: boundary, in: cursor..<body.endIndex) {
            if cursor != body.startIndex { parts.append(body[cursor..<range.lowerBound]) }
            cursor = range.upperBound
        }
        func content(_ part: Data) -> Data {
            let start = part.range(of: Data("\r\n\r\n".utf8))!.upperBound
            return Data(part[start..<(part.endIndex - 2)]) // drop trailing CRLF
        }
        let meta = try! JSONSerialization.jsonObject(with: content(parts[0])) as! [String: Any]
        return (meta, content(parts[1]))
    }

    private func respond(_ status: Int, json: [String: Any], headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: json),
         HTTPURLResponse(url: URL(string: "https://fake")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

extension Data {
    init(_ string: String) { self.init(string.utf8) }
}

final class StaticTokens: AccessTokenProvider {
    var token = "token-1"
    var invalidations = 0
    func accessToken() async throws -> String { token }
    func invalidate() { invalidations += 1 }
}
