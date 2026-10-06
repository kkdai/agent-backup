import CryptoKit
import Foundation
import Network

public protocol AccessTokenProvider: AnyObject {
    func accessToken() async throws -> String
    /// Called after a 401 so the next `accessToken()` refreshes.
    func invalidate()
}

/// The OAuth client from Google Cloud Console (type "Desktop app").
/// For a desktop app the "secret" is not confidential; Google still requires it in the token exchange.
public struct GoogleClientConfig: Codable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Accepts the JSON downloaded from Cloud Console (`{"installed": {...}}`).
    public static func parse(googleJSON data: Data) throws -> GoogleClientConfig {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let installed = root?["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              let secret = installed["client_secret"] as? String else {
            throw GoogleAuthError.badClientConfig
        }
        return GoogleClientConfig(clientID: id, clientSecret: secret)
    }

    public static func defaultLocation(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        appSupportDirectory(home: home).appendingPathComponent("google-oauth-client.json")
    }
}

public enum GoogleAuthError: LocalizedError, Equatable {
    case badClientConfig
    case notLoggedIn
    case loginFailed(String)
    case tokenRequestFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badClientConfig: "Not a Google OAuth client JSON (expected a \"Desktop app\" client with an \"installed\" section)."
        case .notLoggedIn: "Not logged in to Google Drive. Run `agent-backup drive login`."
        case .loginFailed(let reason): "Google login failed: \(reason)"
        case .tokenRequestFailed(let status, let body): "Google token request failed (\(status)): \(body)"
        }
    }
}

/// Google OAuth for installed apps: system browser + loopback redirect + PKCE.
/// The refresh token lives in Keychain; access tokens only in memory.
public final class GoogleOAuth: AccessTokenProvider {
    /// Only files this app created — never the rest of the user's Drive.
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    static let refreshTokenAccount = "google-refresh-token"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    let client: GoogleClientConfig
    let secrets: SecretStore
    let http: HTTPTransport
    /// Parallel uploads ask for tokens concurrently: guard the cache and share one refresh.
    private let lock = NSLock()
    private var cached: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    public init(client: GoogleClientConfig, secrets: SecretStore, http: HTTPTransport = URLSessionTransport()) {
        self.client = client
        self.secrets = secrets
        self.http = http
    }

    public var isLoggedIn: Bool { secrets.get(Self.refreshTokenAccount) != nil }

    public func login(openBrowser: (URL) -> Void) async throws {
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openBrowser(auth.url!)

        let query = try await receiver.waitForCallback()
        let value = { (name: String) in query.first { $0.name == name }?.value }
        if let error = value("error") { throw GoogleAuthError.loginFailed(error) }
        guard value("state") == state else { throw GoogleAuthError.loginFailed("state mismatch") }
        guard let code = value("code") else { throw GoogleAuthError.loginFailed("no authorization code") }

        let response = try await tokenRequest([
            "code": code, "client_id": client.clientID, "client_secret": client.clientSecret,
            "redirect_uri": redirectURI, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = response["refresh_token"] as? String else {
            throw GoogleAuthError.loginFailed("Google did not return a refresh token")
        }
        try secrets.set(Self.refreshTokenAccount, Data(refresh.utf8))
        cache(response)
    }

    public func accessToken() async throws -> String {
        let task: Task<String, Error> = lock.withLock {
            if let cached, cached.expires > Date().addingTimeInterval(60) {
                return Task { cached.token }
            }
            if let refreshing { return refreshing }
            let task = Task { try await self.refreshAccessToken() }
            refreshing = task
            return task
        }
        defer { lock.withLock { if refreshing == task { refreshing = nil } } }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        guard let refresh = secrets.get(Self.refreshTokenAccount).flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw GoogleAuthError.notLoggedIn
        }
        do {
            let response = try await tokenRequest([
                "refresh_token": refresh, "client_id": client.clientID,
                "client_secret": client.clientSecret, "grant_type": "refresh_token",
            ])
            return cache(response)
        } catch GoogleAuthError.tokenRequestFailed(400, let body) where body.contains("invalid_grant") {
            // Revoked, expired (apps left in "Testing" get 7-day tokens), or password changed.
            secrets.delete(Self.refreshTokenAccount)
            throw GoogleAuthError.notLoggedIn
        }
    }

    public func invalidate() {
        lock.withLock { cached = nil }
    }

    public func logout() async {
        if let refresh = secrets.get(Self.refreshTokenAccount).flatMap({ String(data: $0, encoding: .utf8) }) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(["token": refresh])
            _ = try? await http.send(request)
        }
        secrets.delete(Self.refreshTokenAccount)
        invalidate()
    }

    @discardableResult
    private func cache(_ response: [String: Any]) -> String {
        let token = response["access_token"] as? String ?? ""
        let lifetime = response["expires_in"] as? Double ?? 3600
        lock.withLock { cached = (token, Date().addingTimeInterval(lifetime)) }
        return token
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleAuthError.tokenRequestFailed(response.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    static func randomURLSafe(bytes: Int) -> String {
        SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { Data($0) }.base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackReceiver {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AgentBackup.LoopbackReceiver")
    private let lock = NSLock()
    private var startup: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[URLQueryItem], Error>?
    private var pending: Result<[URLQueryItem], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            startup = continuation
            // State updates arrive on `queue`, so `startup` is consumed exactly once.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    startup?.resume(returning: listener.port?.rawValue ?? 0)
                    startup = nil
                case .failed(let error):
                    startup?.resume(throwing: error)
                    startup = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let pending {
                continuation.resume(with: pending)
            } else {
                callback = continuation
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard pending == nil else { return }
        pending = result
        callback?.resume(with: result)
        callback = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n").first.map(String.init) ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            let isCallback = components?.path == "/" && components?.queryItems != nil

            let body = isCallback
                ? "<html><body style=\"font-family:-apple-system;padding:3em\"><h2>Agent Backup is connected to Google Drive.</h2>You can close this tab.</body></html>"
                : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let items = components?.queryItems { self?.finish(.success(items)) }
        }
    }
}
