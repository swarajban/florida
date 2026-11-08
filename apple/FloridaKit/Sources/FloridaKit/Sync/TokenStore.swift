import Foundation

/// Persists the `ServerConfig` (URL + token) between launches.
public protocol TokenStore: Sendable {
    func load() throws -> ServerConfig?
    func save(_ config: ServerConfig) throws
    func clear() throws
}

/// Keeps the config in memory only; for tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var config: ServerConfig?

    public init(_ config: ServerConfig? = nil) {
        self.config = config
    }

    public func load() throws -> ServerConfig? {
        lock.withLock { config }
    }

    public func save(_ config: ServerConfig) throws {
        lock.withLock { self.config = config }
    }

    public func clear() throws {
        lock.withLock { config = nil }
    }
}

#if canImport(Security)
import Security

/// Stores the config's JSON as a generic password in the keychain. No access group, so it is
/// private to the app that wrote it; readable after the first unlock so background refreshes work.
public struct KeychainTokenStore: TokenStore {
    public static let service = "com.swarajban.florida"
    public static let account = "server"

    public init() {}

    public func load() throws -> ServerConfig? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(ServerConfig.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ config: ServerConfig) throws {
        let data = try JSONEncoder().encode(config)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

public struct KeychainError: Error, Sendable {
    public let status: OSStatus
}
#endif
