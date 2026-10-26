import CryptoKit
import Foundation

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
    mutating func reroll(now: Date = Date()) -> String {
        let secret = Self.makeSecret()
        secretHash = Self.hash(secret)
        rolledAt = now
        lastUsedAt = nil
        lastUsedDevice = nil
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

/// The access tokens, shared by Settings and the HTTP server.
final class AccessTokenStore: @unchecked Sendable {
    static let shared = AccessTokenStore()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var tokens: [AccessToken]

    init(defaults: UserDefaults = .standard, key: String = "remoteAccessTokens") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
            let tokens = try? JSONDecoder().decode([AccessToken].self, from: data)
        {
            self.tokens = tokens
        } else {
            self.tokens = []
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
        let data: Data? = lock.withLock {
            body(&tokens)
            return try? JSONEncoder().encode(tokens)
        }
        if let data {
            defaults.set(data, forKey: key)
        }
    }
}
