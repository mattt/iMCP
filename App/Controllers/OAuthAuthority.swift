import CryptoKit
import Foundation
import OSLog

private let log = Logger.server

/// An app that asks to use iMCP: a client registered through RFC 7591,
/// or one that a Client ID Metadata Document describes.
struct OAuthClient: Equatable, Sendable {
    var id: String
    /// The name that the client chose, after ``ClientName/sanitized(_:)``.
    var name: String
    /// The only URIs that the client can be sent back to.
    var redirectURIs: [String]
}

/// An error in the form that OAuth endpoints report it.
struct OAuthError: Error, Equatable, Sendable {
    var code: String
    var description: String
    /// The HTTP status of a token endpoint response.
    var status = 400

    static func invalidRequest(_ description: String) -> Self {
        .init(code: "invalid_request", description: description)
    }
    static func invalidGrant(_ description: String) -> Self { .init(code: "invalid_grant", description: description) }
    static func invalidClient(_ description: String) -> Self { .init(code: "invalid_client", description: description) }
    static func invalidTarget(_ description: String) -> Self { .init(code: "invalid_target", description: description) }
    static let unavailable = OAuthError(
        code: "server_error",
        description: "iMCP couldn't save or read its grants. Try again.",
        status: 503
    )
}

struct OAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
}

/// What the owner decided about an authorization request.
enum OAuthDecision: Equatable, Sendable {
    /// `readOnly` limits the grant to tools that don't change anything.
    case approved(readOnly: Bool)
    case denied
}

/// What iMCP shows the owner when an app asks for access.
struct OAuthApprovalRequest: Equatable, Sendable {
    var id: String
    var clientName: String
    /// The host that the app's authorization response goes to.
    var redirectHost: String
    /// Whether the app's client ID is a URL that the app controls, rather than one that iMCP issued.
    var usesMetadataDocument: Bool
    /// Whether the redirect goes to this Mac, so that any app on the Mac could receive it.
    var redirectsToThisMac: Bool
}

/// iMCP's own OAuth 2.1 authorization server for public access,
/// following the MCP authorization spec, version 2025-11-25.
///
/// Authorization codes and access tokens live in memory only:
/// codes last a minute, access tokens an hour, and a restart ends both.
/// Grants and their refresh tokens' hashes are saved in the Keychain, so access lasts until revoked.
/// Every secret is random and stored as a SHA-256 digest.
final class OAuthAuthority: @unchecked Sendable {
    static let shared = OAuthAuthority()

    static let accessTokenLifetime: TimeInterval = 3600
    static let codeLifetime: TimeInterval = 60
    /// How long iMCP remembers a used code, to end the grant if the code comes back.
    static let usedCodeMemory: TimeInterval = 600
    static let pendingLifetime: TimeInterval = 130
    static let maximumPending = 16
    static let maximumRegisteredClients = 100
    static let maximumRetiredRefreshTokens = 5
    static let accessPrefix = "imcpat_"
    static let refreshPrefix = "imcprt_"
    static let clientPrefix = "imcpc_"
    static let scope = "mcp"

    typealias MetadataFetch = @Sendable (URL) async throws -> Data

    private struct Code {
        var client: OAuthClient
        var redirectURI: String
        var challenge: String
        var resource: String
        var readOnly: Bool
        var redirectHost: String
        var expires: Date
    }

    private struct AccessEntry {
        var grantID: UUID
        var resource: String
        var expires: Date
    }

    private struct Pending {
        var request: OAuthApprovalRequest
        var client: OAuthClient
        var redirectURI: String
        var state: String?
        var challenge: String
        var resource: String
        var expires: Date
        var decision: OAuthDecision?
    }

    /// What `/authorize` does next with a pending request.
    enum PendingOutcome: Equatable {
        case unknown
        case waiting
        case denied(redirectURI: String, state: String?)
        case approved(redirectURI: String, state: String?, code: String)
    }

    private let storage: any OAuthGrantStorage
    private let fetchMetadata: MetadataFetch
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    private var grants: [OAuthGrant] = []
    private var loadError: (any Error)?
    /// Grants whose revocation iMCP couldn't save. They stay unusable until a save succeeds.
    private var suspended: Set<UUID> = []
    private var registered: [String: (client: OAuthClient, at: Date)] = [:]
    private var metadataClients: [String: (client: OAuthClient, expires: Date)] = [:]
    private var pending: [String: Pending] = [:]
    private var codes: [Data: Code] = [:]
    private var usedCodes: [Data: (grantID: UUID, expires: Date)] = [:]
    private var accessTokens: [Data: AccessEntry] = [:]
    private var changeHandler: (@Sendable () -> Void)?
    private var tokenFailures = FailedAuthLimiter()
    private var registrations = FailedAuthLimiter(maximumFailures: 20, window: 60, blockDuration: 60)
    private var authorizations = FailedAuthLimiter(maximumFailures: 10, window: 60, blockDuration: 60)

    init(
        storage: any OAuthGrantStorage = KeychainOAuthGrantStorage(),
        fetchMetadata: @escaping MetadataFetch = ClientMetadataFetcher.fetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.fetchMetadata = fetchMetadata
        self.now = now
        lock.withLock { _ = try? loadIfNeeded(force: true) }
    }

    /// Sets a function that runs after the list of grants changes, such as for Settings to refresh.
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    private func notifyChange() {
        lock.withLock { changeHandler }?()
    }

    // MARK: Pure rules

    static func hash(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }

    static func makeSecret(prefix: String) -> String {
        prefix + AccessToken.makeSecret().dropFirst(AccessToken.secretPrefix.count)
    }

    /// Whether `verifier` produces `challenge` under PKCE's S256 method.
    static func verifyPKCE(verifier: String, challenge: String) -> Bool {
        guard isValidVerifier(verifier), isValidChallenge(challenge) else { return false }
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let computed = Data(base64URL(digest).utf8)
        let expected = Data(challenge.utf8)
        // Compare every byte, so that the time doesn't show how much matched.
        guard computed.count == expected.count else { return false }
        return zip(computed, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// RFC 7636: 43 to 128 characters from the unreserved set.
    static func isValidVerifier(_ value: String) -> Bool {
        (43 ... 128).contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                    || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            }
    }

    /// An S256 challenge is a SHA-256 digest in Base64URL without padding: 43 characters.
    static func isValidChallenge(_ value: String) -> Bool {
        value.utf8.count == 43
            && value.utf8.allSatisfy { byte in
                (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                    || byte == 0x2D || byte == 0x5F
            }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether a client may register this redirect URI:
    /// HTTPS, or HTTP to this Mac's loopback address for apps that run on it.
    /// It can't carry a fragment or a user name, because those make the destination unclear.
    static func isAllowedRedirectURI(_ value: String) -> Bool {
        guard value.utf8.count <= 512, let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
            components.fragment == nil, components.user == nil, components.password == nil
        else { return false }
        switch scheme {
        case "https": return true
        case "http": return isLoopbackHost(host)
        default: return false
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
    }

    /// The URI of this server's MCP endpoint, if `presented` names it.
    /// Accepts the endpoint's own URI and the bare origin that RFC 8707 also allows,
    /// with a lowercase or uppercase scheme and host.
    static func canonicalResource(_ presented: String?, host: String) -> String? {
        let canonical = FunnelPolicy.publicURL(host: host)
        guard let presented else { return canonical }
        guard let components = URLComponents(string: presented), components.scheme?.lowercased() == "https",
            components.host?.lowercased() == host, components.port == nil || components.port == 443,
            components.query == nil, components.fragment == nil, components.user == nil
        else { return nil }
        return ["", "/", "/mcp"].contains(components.path) ? canonical : nil
    }

    // MARK: Limits

    /// The seconds until failed token requests may try again, or `nil` if they may now.
    func tokenRetryAfter() -> Int? {
        lock.withLock { tokenFailures.retryAfter(now: now()) }
    }

    func recordTokenFailure() {
        lock.withLock { tokenFailures.recordFailure(now: now()) }
    }

    /// Counts a registration and returns the seconds to wait if there are too many.
    func admitRegistration() -> Int? {
        lock.withLock {
            let time = now()
            if let wait = registrations.retryAfter(now: time) { return wait }
            registrations.recordFailure(now: time)
            return registrations.retryAfter(now: time)
        }
    }

    /// Counts a new authorization request and returns the seconds to wait if there are too many.
    func admitAuthorization() -> Int? {
        lock.withLock {
            let time = now()
            if let wait = authorizations.retryAfter(now: time) { return wait }
            authorizations.recordFailure(now: time)
            return authorizations.retryAfter(now: time)
        }
    }

    // MARK: Clients

    /// Registers a client for RFC 7591 dynamic registration.
    func register(name: String?, redirectURIs: [String]) throws -> OAuthClient {
        guard !redirectURIs.isEmpty, redirectURIs.count <= 5, redirectURIs.allSatisfy(Self.isAllowedRedirectURI) else {
            throw OAuthError(
                code: "invalid_redirect_uri",
                description: "Use up to 5 HTTPS redirect URIs, or HTTP URIs on localhost, 127.0.0.1, or [::1]."
            )
        }
        let client = OAuthClient(
            id: Self.makeSecret(prefix: Self.clientPrefix),
            name: ClientName.sanitized(name ?? ""),
            redirectURIs: redirectURIs
        )
        lock.withLock {
            if registered.count >= Self.maximumRegisteredClients,
                let oldest = registered.min(by: { $0.value.at < $1.value.at })
            {
                registered.removeValue(forKey: oldest.key)
            }
            registered[client.id] = (client, now())
        }
        return client
    }

    /// The client with this ID, fetching its metadata document if the ID is an HTTPS URL.
    func resolveClient(id: String) async -> OAuthClient? {
        if let known = lock.withLock({ registered[id]?.client }) { return known }
        guard let url = Self.metadataURL(for: id) else { return nil }
        let cached: OAuthClient? = lock.withLock {
            guard let entry = metadataClients[id], entry.expires > now() else { return nil }
            return entry.client
        }
        if let cached { return cached }
        guard let data = try? await fetchMetadata(url), let client = Self.parseMetadataDocument(data, url: id) else {
            return nil
        }
        lock.withLock {
            if metadataClients.count >= Self.maximumRegisteredClients { metadataClients.removeAll() }
            metadataClients[id] = (client, now().addingTimeInterval(3600))
        }
        return client
    }

    /// The URL in a Client ID Metadata Document client ID: HTTPS with a path, and nothing else.
    static func metadataURL(for clientID: String) -> URL? {
        guard clientID.hasPrefix("https://"), clientID.utf8.count <= 512, let url = URL(string: clientID),
            let components = URLComponents(string: clientID), components.fragment == nil, components.query == nil,
            components.user == nil, components.password == nil, components.port == nil,
            components.path.count > 1, url.host() != nil
        else { return nil }
        return url
    }

    /// Reads a Client ID Metadata Document, which must name its own URL as its client ID.
    static func parseMetadataDocument(_ data: Data, url: String) -> OAuthClient? {
        guard data.count <= 16 * 1024,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["client_id"] as? String == url,
            let uris = object["redirect_uris"] as? [String], !uris.isEmpty, uris.count <= 5,
            uris.allSatisfy(isAllowedRedirectURI)
        else { return nil }
        // iMCP issues no client secrets, so a document can't ask for authentication.
        if let method = object["token_endpoint_auth_method"] as? String, method != "none" { return nil }
        let name = (object["client_name"] as? String).map(ClientName.sanitized)
        let fallback = URL(string: url)?.host() ?? ClientName.unnamed
        return OAuthClient(id: url, name: name ?? fallback, redirectURIs: uris)
    }

    // MARK: Authorization requests

    /// Records a request that waits for the owner's decision.
    /// Returns its ID, or `nil` if too many wait.
    func beginPending(
        client: OAuthClient,
        redirectURI: String,
        state: String?,
        challenge: String,
        resource: String
    ) -> OAuthApprovalRequest? {
        let host = URLComponents(string: redirectURI)?.host?.lowercased() ?? ""
        return lock.withLock {
            let time = now()
            pending = pending.filter { $0.value.expires > time }
            guard pending.count < Self.maximumPending else { return nil }
            let request = OAuthApprovalRequest(
                id: Self.makeSecret(prefix: "imcpa_"),
                clientName: client.name,
                redirectHost: host,
                usesMetadataDocument: client.id.hasPrefix("https://"),
                redirectsToThisMac: Self.isLoopbackHost(host)
            )
            pending[request.id] = Pending(
                request: request,
                client: client,
                redirectURI: redirectURI,
                state: state,
                challenge: challenge,
                resource: resource,
                expires: time.addingTimeInterval(Self.pendingLifetime)
            )
            return request
        }
    }

    func setDecision(_ decision: OAuthDecision, for id: String) {
        lock.withLock { pending[id]?.decision = decision }
    }

    /// Where a pending request stands.
    /// An approval issues the authorization code and ends the request.
    func outcome(ofPending id: String) -> PendingOutcome {
        lock.withLock {
            guard let entry = pending[id] else { return .unknown }
            let time = now()
            guard entry.expires > time else {
                pending.removeValue(forKey: id)
                return .denied(redirectURI: entry.redirectURI, state: entry.state)
            }
            switch entry.decision {
            case nil:
                return .waiting
            case .denied:
                pending.removeValue(forKey: id)
                return .denied(redirectURI: entry.redirectURI, state: entry.state)
            case .approved(let readOnly):
                pending.removeValue(forKey: id)
                let code = Self.makeSecret(prefix: "imcpx_")
                codes = codes.filter { $0.value.expires > time }
                codes[Self.hash(code)] = Code(
                    client: entry.client,
                    redirectURI: entry.redirectURI,
                    challenge: entry.challenge,
                    resource: entry.resource,
                    readOnly: readOnly,
                    redirectHost: entry.request.redirectHost,
                    expires: time.addingTimeInterval(Self.codeLifetime)
                )
                return .approved(redirectURI: entry.redirectURI, state: entry.state, code: code)
            }
        }
    }

    /// The request to show the owner for a pending ID.
    func approvalRequest(forPending id: String) -> OAuthApprovalRequest? {
        lock.withLock { pending[id]?.request }
    }

    // MARK: Tokens

    /// Trades an authorization code for tokens, once.
    func exchange(
        code: String,
        clientID: String,
        redirectURI: String,
        verifier: String,
        resource: String?,
        host: String
    ) throws -> OAuthTokens {
        defer { notifyChange() }
        return try lock.withLock {
            let time = now()
            let digest = Self.hash(code)
            usedCodes = usedCodes.filter { $0.value.expires > time }
            guard let entry = codes.removeValue(forKey: digest) else {
                // A code that comes back may be stolen, so end the grant that it created.
                if let used = usedCodes[digest] {
                    try? revokeLocked(used.grantID)
                    log.notice("An authorization code was used twice, so iMCP revoked its grant")
                }
                throw OAuthError.invalidGrant("The authorization code isn't valid.")
            }
            guard entry.expires > time else { throw OAuthError.invalidGrant("The authorization code expired.") }
            guard entry.client.id == clientID, entry.redirectURI == redirectURI else {
                throw OAuthError.invalidGrant("The code was issued for another client or redirect URI.")
            }
            guard Self.verifyPKCE(verifier: verifier, challenge: entry.challenge) else {
                throw OAuthError.invalidGrant("The code verifier doesn't match.")
            }
            if let resource {
                guard Self.canonicalResource(resource, host: host) == entry.resource else {
                    throw OAuthError.invalidTarget("The code was issued for another resource.")
                }
            }
            try loadIfNeeded()

            let refresh = Self.makeSecret(prefix: Self.refreshPrefix)
            let grant = OAuthGrant(
                id: UUID(),
                clientID: entry.client.id,
                clientName: entry.client.name,
                redirectHost: entry.redirectHost,
                resource: entry.resource,
                permissions: entry.readOnly ? .readOnly : .allTools,
                createdAt: time,
                refreshHash: Self.hash(refresh)
            )
            // An app that connects again replaces its earlier grant for the same endpoint.
            let replaced = grants.filter { $0.clientID == grant.clientID && $0.resource == grant.resource }
            var changed = grants.filter { old in !replaced.contains { $0.id == old.id } }
            changed.append(grant)
            try save(changed)
            for old in replaced { dropAccessTokens(for: old.id) }
            usedCodes[digest] = (grant.id, time.addingTimeInterval(Self.usedCodeMemory))
            return OAuthTokens(
                accessToken: issueAccessToken(for: grant, at: time),
                refreshToken: refresh,
                expiresIn: Int(Self.accessTokenLifetime)
            )
        }
    }

    /// Trades a refresh token for new tokens. The old refresh token stops working.
    /// A refresh token that rotation already replaced ends the grant.
    func refresh(refreshToken: String, clientID: String, resource: String?, host: String) throws -> OAuthTokens {
        defer { notifyChange() }
        return try lock.withLock {
            let time = now()
            let digest = Self.hash(refreshToken)
            try loadIfNeeded()
            guard let index = grants.firstIndex(where: { $0.refreshHash == digest }) else {
                if let reused = grants.first(where: { $0.retiredRefreshHashes.contains(digest) }) {
                    try? revokeLocked(reused.id)
                    log.notice("A retired refresh token came back, so iMCP revoked its grant")
                }
                throw OAuthError.invalidGrant("The refresh token isn't valid.")
            }
            let grant = grants[index]
            guard !suspended.contains(grant.id), grant.clientID == clientID else {
                throw OAuthError.invalidGrant("The refresh token isn't valid.")
            }
            if let resource, Self.canonicalResource(resource, host: host) != grant.resource {
                throw OAuthError.invalidTarget("The grant is for another resource.")
            }

            let next = Self.makeSecret(prefix: Self.refreshPrefix)
            var rotated = grant
            rotated.retiredRefreshHashes.append(grant.refreshHash)
            rotated.retiredRefreshHashes = Array(rotated.retiredRefreshHashes.suffix(Self.maximumRetiredRefreshTokens))
            rotated.refreshHash = Self.hash(next)
            rotated.lastUsedAt = time
            var changed = grants
            changed[index] = rotated
            try save(changed)
            return OAuthTokens(
                accessToken: issueAccessToken(for: rotated, at: time),
                refreshToken: next,
                expiresIn: Int(Self.accessTokenLifetime)
            )
        }
    }

    /// The grant that an access token belongs to, if the token is good for `resource` now.
    func authenticate(accessToken: String, resource: String) -> OAuthGrant? {
        guard accessToken.hasPrefix(Self.accessPrefix) else { return nil }
        let digest = Self.hash(accessToken)
        return lock.withLock {
            let time = now()
            guard let entry = accessTokens[digest] else { return nil }
            guard entry.expires > time else {
                accessTokens.removeValue(forKey: digest)
                return nil
            }
            guard entry.resource == resource, !suspended.contains(entry.grantID),
                let index = grants.firstIndex(where: { $0.id == entry.grantID }), grants[index].resource == resource
            else { return nil }
            grants[index].lastUsedAt = time
            return grants[index]
        }
    }

    func grant(id: UUID) -> OAuthGrant? {
        lock.withLock { suspended.contains(id) ? nil : grants.first { $0.id == id } }
    }

    var allGrants: [OAuthGrant] {
        lock.withLock {
            _ = try? loadIfNeeded()
            return grants
        }
    }

    /// Why iMCP can't read its grants, or `nil` if it can.
    var storageError: String? {
        lock.withLock {
            do {
                try loadIfNeeded()
                return nil
            } catch {
                return "iMCP couldn't read its connected apps from the Keychain: \(error.localizedDescription)"
            }
        }
    }

    /// Ends a grant. Its access and refresh tokens stop working at once.
    /// If iMCP can't save the change, the grant stays unusable and this throws.
    func revoke(id: UUID) throws {
        defer { notifyChange() }
        try lock.withLock { try revokeLocked(id) }
    }

    // MARK: Internals

    private func issueAccessToken(for grant: OAuthGrant, at time: Date) -> String {
        let token = Self.makeSecret(prefix: Self.accessPrefix)
        accessTokens = accessTokens.filter { $0.value.expires > time }
        accessTokens[Self.hash(token)] = AccessEntry(
            grantID: grant.id,
            resource: grant.resource,
            expires: time.addingTimeInterval(Self.accessTokenLifetime)
        )
        return token
    }

    private func dropAccessTokens(for id: UUID) {
        accessTokens = accessTokens.filter { $0.value.grantID != id }
    }

    private func revokeLocked(_ id: UUID) throws {
        // Stop the tokens first, so that a failed save can't leave them working.
        dropAccessTokens(for: id)
        usedCodes = usedCodes.filter { $0.value.grantID != id }
        suspended.insert(id)
        try loadIfNeeded()
        try save(grants.filter { $0.id != id })
        suspended.remove(id)
    }

    /// Saves the list, and keeps it only if the save works.
    private func save(_ changed: [OAuthGrant]) throws {
        do {
            try storage.save(changed)
        } catch {
            log.error("Failed to save OAuth grants: \(String(describing: error), privacy: .public)")
            throw OAuthError.unavailable
        }
        grants = changed
    }

    private func loadIfNeeded(force: Bool = false) throws {
        guard force || loadError != nil else { return }
        do {
            grants = try storage.load()
            loadError = nil
        } catch {
            if loadError == nil {
                log.error("Failed to load OAuth grants: \(String(describing: error), privacy: .public)")
            }
            grants = []
            loadError = error
            throw OAuthError.unavailable
        }
    }
}
