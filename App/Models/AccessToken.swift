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
final class AccessTokenStore: @unchecked Sendable {
    static let shared = AccessTokenStore()

    private let storage: any AccessTokenStorage
    private let lock = NSLock()
    private var tokens: [AccessToken]

    init(
        storage: any AccessTokenStorage = KeychainAccessTokenStorage(),
        defaults: UserDefaults = .standard,
        key: String = "remoteAccessTokens"
    ) {
        self.storage = storage
        // Earlier builds of this unreleased branch used preferences. Discard those tokens.
        defaults.removeObject(forKey: key)
        do {
            tokens = try storage.load()
        } catch {
            Logger.server.error("Failed to load access tokens: \(String(describing: error), privacy: .public)")
            tokens = []
        }
    }

    var all: [AccessToken] {
        lock.withLock { tokens }
    }

    func token(id: UUID) -> AccessToken? {
        lock.withLock { tokens.first { $0.id == id } }
    }

    /// The token whose secret this is, if any.
    func token(secret: String) -> AccessToken? {
        guard secret.hasPrefix(AccessToken.secretPrefix) else { return nil }
        let hash = AccessToken.hash(secret)
        return lock.withLock { tokens.first { $0.secretHash == hash } }
    }

    func add(_ token: AccessToken) {
        update { $0.append(token) }
    }

    enum BindingError: Error {
        case invalidToken
        case differentDevice
    }

    /// Claims an unbound token, or records another session from its bound node.
    /// Checks the secret again in case it was replaced while the session started.
    func bind(_ token: AccessToken, to device: AccessToken.BoundDevice, now: Date = Date()) throws {
        try lock.withLock {
            guard let index = tokens.firstIndex(where: { $0.id == token.id }),
                tokens[index].secretHash == token.secretHash
            else {
                throw BindingError.invalidToken
            }
            if let bound = tokens[index].boundDevice, bound.stableID != device.stableID {
                throw BindingError.differentDevice
            }
            tokens[index].boundDevice = device
            tokens[index].lastUsedAt = now
            tokens[index].lastUsedDevice = device.name
            persist()
        }
    }

    func remove(id: UUID) {
        update { $0.removeAll { $0.id == id } }
    }

    /// Changes one token and returns the changed copy.
    @discardableResult
    func modify<T>(id: UUID, _ body: (inout AccessToken) -> T) -> T? {
        var result: T?
        update { tokens in
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
            result = body(&tokens[index])
        }
        return result
    }

    private func update(_ body: (inout [AccessToken]) -> Void) {
        lock.withLock {
            body(&tokens)
            persist()
        }
    }

    /// Called with the lock held, so an older write cannot replace a newer binding.
    private func persist() {
        do {
            try storage.save(tokens)
        } catch {
            Logger.server.error("Failed to save access tokens: \(String(describing: error), privacy: .public)")
        }
    }
}
