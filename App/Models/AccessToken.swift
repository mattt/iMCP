import CryptoKit
import Foundation
import OSLog
import Security

/// A named credential that lets a client on another device use iMCP over HTTP.
///
/// iMCP keeps only a hash of the secret,
/// so the secret is shown once, when the token is created or re-rolled.
struct AccessToken: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var permissions: ToolPermissions
    /// The SHA-256 digest of the secret that clients send.
    var secretHash: Data
    let createdAt: Date
    /// When the secret was last replaced.
    var rolledAt: Date?
    /// When a client last started a session with the token.
    var lastUsedAt: Date?
    /// The Tailscale device that last started a session with the token.
    var lastUsedDevice: String?
    /// The device that first started a session with this secret.
    var boundDevice: BoundDevice?

    struct BoundDevice: Codable, Hashable, Sendable {
        let stableID: String
        let name: String
    }

    /// Creates a token and returns it with its secret.
    static func make(name: String, permissions: ToolPermissions, now: Date = Date()) -> (AccessToken, String) {
        let secret = makeSecret()
        let token = AccessToken(
            id: UUID(),
            name: name,
            permissions: permissions,
            secretHash: hash(secret),
            createdAt: now
        )
        return (token, secret)
    }

    /// Replaces the secret and returns the new one.
    /// The old secret stops working; the name and permissions stay the same.
    /// The new secret is unbound until a device starts a session with it.
    mutating func reroll(now: Date = Date()) -> String {
        let secret = Self.makeSecret()
        secretHash = Self.hash(secret)
        rolledAt = now
        lastUsedAt = nil
        lastUsedDevice = nil
        boundDevice = nil
        return secret
    }

    static let secretPrefix = "imcp_"

    /// A prefix and 256 random bits, Base64URL-encoded without padding.
    static func makeSecret() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return secretPrefix + encoded
    }

    static func hash(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }
}

/// The tools that an access token allows.
///
/// A token never gives access to a service or tool that's off in iMCP;
/// these permissions can only narrow what iMCP already allows.
enum ToolPermissions: Codable, Hashable, Sendable {
    /// Tools that only read data, including read-only tools that later versions add.
    case readOnly
    /// Every tool, including tools that later versions add.
    case allTools
    /// Only the tools with these names.
    case custom(Set<String>)

    func allows(_ tool: Tool) -> Bool {
        switch self {
        case .readOnly: tool.annotations.readOnlyHint == true
        case .allTools: true
        case .custom(let names): names.contains(tool.name)
        }
    }

    /// The tool names that these permissions allow, out of the given tools.
    func allowedNames(in tools: [Tool]) -> Set<String> {
        Set(tools.filter(allows).map(\.name))
    }
}

/// Storage for the complete access token list.
protocol AccessTokenStorage {
    func load() throws -> [AccessToken]
    func save(_ tokens: [AccessToken]) throws
}

/// Stores access tokens in memory, for tests.
final class InMemoryAccessTokenStorage: AccessTokenStorage {
    var tokens: [AccessToken] = []

    func load() throws -> [AccessToken] { tokens }

    func save(_ tokens: [AccessToken]) throws {
        self.tokens = tokens
    }
}

/// Stores the token list as password data in a separate Keychain item.
/// Uses the same Release protection and Debug fallback as client credentials.
struct KeychainAccessTokenStorage: AccessTokenStorage {
    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(Bundle.main.bundleIdentifier ?? LocalSocket.appBundleIdentifier).access-tokens",
            kSecAttrAccount: "remote-access-tokens",
        ]
        if KeychainClientRecordStorage.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    func load() throws -> [AccessToken] {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainClientRecordStorage.Error.status(status) }
        guard let data = result as? Data else {
            throw KeychainClientRecordStorage.Error.status(errSecDecode)
        }
        return try JSONDecoder().decode([AccessToken].self, from: data)
    }

    func save(_ tokens: [AccessToken]) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [CFString: Any] = [kSecValueData: data]
        var item = baseQuery
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(attributes) { $1 }
            if KeychainClientRecordStorage.usesDataProtectionKeychain {
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainClientRecordStorage.Error.status(status) }
    }
}

/// The access tokens, shared by Settings and the HTTP server.
///
/// Every change saves the complete list before it takes effect,
/// and a change that iMCP can't save throws.
/// If the list can't be read, the store has no tokens
/// and rejects changes until a later read succeeds,
/// so that a save can't replace tokens that iMCP never read.
final class AccessTokenStore: @unchecked Sendable {
    static let shared = AccessTokenStore()

    enum StorageError: LocalizedError {
        /// iMCP couldn't read the saved tokens.
        case unavailable(any Error)
        /// iMCP couldn't save a change.
        case saveFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .unavailable(let error):
                "iMCP couldn't read its access tokens from the Keychain: \(error.localizedDescription)"
            case .saveFailed(let error):
                "iMCP couldn't save its access tokens to the Keychain: \(error.localizedDescription)"
            }
        }
    }

    private let storage: any AccessTokenStorage
    private let lock = NSLock()
    private var tokens: [AccessToken] = []
    /// Why the last read failed, until a read succeeds.
    private var loadError: (any Error)?
    /// Tokens whose deletion, re-roll, or edit iMCP couldn't save.
    /// They can't be used until a change to them is saved,
    /// so that a failed save never leaves a revoked token in use.
    private var suspended: Set<UUID> = []

    init(
        storage: any AccessTokenStorage = KeychainAccessTokenStorage(),
        defaults: UserDefaults = .standard,
        key: String = "remoteAccessTokens"
    ) {
        self.storage = storage
        // Earlier builds of this unreleased branch used preferences. Discard those tokens.
        defaults.removeObject(forKey: key)
        lock.withLock { _ = try? loadIfNeeded(force: true) }
    }

    /// Why iMCP can't read its tokens, or `nil` if it can.
    var storageError: StorageError? {
        lock.withLock {
            do {
                try loadIfNeeded()
                return nil
            } catch let error as StorageError {
                return error
            } catch {
                return .unavailable(error)
            }
        }
    }

    var all: [AccessToken] {
        lock.withLock {
            _ = try? loadIfNeeded()
            return tokens
        }
    }

    /// The token with this ID, unless it's suspended.
    func token(id: UUID) -> AccessToken? {
        lock.withLock { tokens.first { $0.id == id && !suspended.contains(id) } }
    }

    /// The token whose secret this is, if any, unless it's suspended.
    func token(secret: String) -> AccessToken? {
        guard secret.hasPrefix(AccessToken.secretPrefix) else { return nil }
        let hash = AccessToken.hash(secret)
        return lock.withLock {
            guard (try? loadIfNeeded()) != nil else { return nil }
            return tokens.first { $0.secretHash == hash && !suspended.contains($0.id) }
        }
    }

    func add(_ token: AccessToken) throws {
        try update { $0.append(token) }
    }

    enum BindingError: Error {
        case invalidToken
        case differentDevice
    }

    /// Claims an unbound token, or records another session from its bound node.
    /// Checks the secret again in case it was replaced while the session started.
    /// Throws a ``StorageError`` if iMCP can't save the binding,
    /// and then the token stays as it was.
    func bind(_ token: AccessToken, to device: AccessToken.BoundDevice, now: Date = Date()) throws {
        try update { tokens in
            guard let index = tokens.firstIndex(where: { $0.id == token.id }),
                tokens[index].secretHash == token.secretHash,
                !suspended.contains(token.id)
            else {
                throw BindingError.invalidToken
            }
            if let bound = tokens[index].boundDevice, bound.stableID != device.stableID {
                throw BindingError.differentDevice
            }
            tokens[index].boundDevice = device
            tokens[index].lastUsedAt = now
            tokens[index].lastUsedDevice = device.name
        }
    }

    /// Deletes a token.
    /// If iMCP can't save the deletion, the token is suspended and this throws.
    func remove(id: UUID) throws {
        try update(suspendingOnFailure: id) { $0.removeAll { $0.id == id } }
    }

    /// Changes one token and returns the result of the change.
    /// If iMCP can't save the change, the token is suspended and this throws.
    @discardableResult
    func modify<T>(id: UUID, _ body: (inout AccessToken) -> T) throws -> T? {
        var result: T?
        try update(suspendingOnFailure: id) { tokens in
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
            result = body(&tokens[index])
        }
        return result
    }

    /// Changes a copy of the list, saves it, and then keeps it.
    /// The lock stays held, so an older write cannot replace a newer binding.
    private func update(
        suspendingOnFailure id: UUID? = nil,
        _ body: (inout [AccessToken]) throws -> Void
    ) throws {
        try lock.withLock {
            try loadIfNeeded()
            var changed = tokens
            try body(&changed)
            do {
                try storage.save(changed)
            } catch {
                Logger.server.error("Failed to save access tokens: \(String(describing: error), privacy: .public)")
                if let id { suspended.insert(id) }
                throw StorageError.saveFailed(error)
            }
            tokens = changed
            if let id { suspended.remove(id) }
        }
    }

    /// Reads the tokens if the last read failed. Called with the lock held.
    private func loadIfNeeded(force: Bool = false) throws {
        guard force || loadError != nil else { return }
        do {
            tokens = try storage.load()
            loadError = nil
        } catch {
            if loadError == nil {
                Logger.server.error("Failed to load access tokens: \(String(describing: error), privacy: .public)")
            }
            tokens = []
            loadError = error
            throw StorageError.unavailable(error)
        }
    }
}
