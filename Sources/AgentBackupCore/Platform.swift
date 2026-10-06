import Foundation
import Security

/// Network seam so the Google Drive store can be tested against a fake Drive.
public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Small secrets that stay on this Mac: the Google refresh token and unlocked backup keys.
public protocol SecretStore {
    func get(_ account: String) -> Data?
    func set(_ account: String, _ data: Data) throws
    func delete(_ account: String)
}

public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "AgentBackup") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func set(_ account: String, _ data: Data) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func get(_ account: String) -> Data? { values[account] }
    public func set(_ account: String, _ data: Data) throws { values[account] = data }
    public func delete(_ account: String) { values[account] = nil }
}

/// `~/Library/Application Support/AgentBackup`
public func appSupportDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
    home.appendingPathComponent("Library/Application Support/AgentBackup", isDirectory: true)
}
