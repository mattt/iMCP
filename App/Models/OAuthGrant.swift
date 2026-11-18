import Foundation
import OSLog
import Security

/// An app that the owner approved to use iMCP through public access, such as a cloud agent.
///
/// A grant lives until the owner revokes it.
/// iMCP keeps only hashes of the refresh tokens, like it does for access tokens.
struct OAuthGrant: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let clientID: String
    var clientName: String
    /// The host of the redirect URI that the owner approved, shown in Settings.
    var redirectHost: String
    /// The MCP endpoint that the grant's tokens work for, such as `https://mac.example.ts.net/mcp`.
    var resource: String
    var permissions: ToolPermissions
    let createdAt: Date
    var lastUsedAt: Date?
    /// The SHA-256 digest of the current refresh token.
    var refreshHash: Data
    /// Digests of refresh tokens that rotation replaced.
    /// A client that presents one has leaked it or lost track of its tokens, so the grant ends.
    var retiredRefreshHashes: [Data] = []
}

/// Storage for the complete list of grants.
protocol OAuthGrantStorage {
    func load() throws -> [OAuthGrant]
    func save(_ grants: [OAuthGrant]) throws
}

/// Stores grants in memory, for tests.
final class InMemoryOAuthGrantStorage: OAuthGrantStorage {
    var grants: [OAuthGrant] = []
    var failsToSave = false

    func load() throws -> [OAuthGrant] { grants }

    func save(_ grants: [OAuthGrant]) throws {
        if failsToSave { throw KeychainClientRecordStorage.Error.status(errSecIO) }
        self.grants = grants
    }
}

/// Stores the grant list as password data in its own Keychain item,
/// with the same protection as the access token list.
struct KeychainOAuthGrantStorage: OAuthGrantStorage {
    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(Bundle.main.bundleIdentifier ?? LocalSocket.appBundleIdentifier).oauth-grants",
            kSecAttrAccount: "remote-access-oauth-grants",
        ]
        if KeychainClientRecordStorage.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    func load() throws -> [OAuthGrant] {
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
        return try JSONDecoder().decode([OAuthGrant].self, from: data)
    }

    func save(_ grants: [OAuthGrant]) throws {
        let data = try JSONEncoder().encode(grants)
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
