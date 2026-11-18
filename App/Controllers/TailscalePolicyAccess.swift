import Foundation
import OSLog
import Security

// MARK: - Policy edit

/// The one change that iMCP makes to a Tailscale policy file: a `nodeAttrs` entry that gives this Mac
/// the `funnel` attribute, which is what allows a public address.
///
/// The policy is edited only when it is plain JSON. Tailscale also accepts HuJSON, which has comments
/// and trailing commas. Writing a HuJSON file back as JSON would delete the owner's comments,
/// so iMCP refuses and the person uses Tailscale's own page instead.
enum TailscalePolicyEdit {
    static let attribute = "funnel"

    enum Failure: Error, Equatable, LocalizedError {
        /// The policy has comments or trailing commas, or is not an object.
        case notPlainJSON
        /// `nodeAttrs` exists but is not a list.
        case unexpectedShape

        var errorDescription: String? {
            switch self {
            case .notPlainJSON:
                "Your Tailscale policy has comments or other extras, so iMCP will not rewrite it. Use the Tailscale page instead."
            case .unexpectedShape:
                "Your Tailscale policy has a nodeAttrs section that iMCP does not understand. Use the Tailscale page instead."
            }
        }
    }

    enum Outcome: Equatable {
        /// Public addresses are already allowed for this target.
        case alreadyAllowed
        /// The policy to send, with the entry added.
        case updated(Data)
    }

    /// The entry that iMCP adds.
    static func entry(target: String) -> [String: Any] {
        ["target": [target], "attr": [attribute]]
    }

    /// The entry as it is shown in the disclosure.
    static func entryText(target: String) -> String {
        """
        {
          "target": ["\(target)"],
          "attr": ["funnel"]
        }
        """
    }

    /// Whether the policy already gives `target` the `funnel` attribute, by its address, `*`, or every member.
    static func allows(policy: Data, target: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: policy)) as? [String: Any],
            let entries = root["nodeAttrs"] as? [[String: Any]]
        else { return false }
        let wide: Set<String> = [target, "*", "autogroup:member"]
        return entries.contains { entry in
            let attrs = entry["attr"] as? [String] ?? []
            let targets = entry["target"] as? [String] ?? []
            return attrs.contains(attribute) && !wide.isDisjoint(with: targets)
        }
    }

    /// Adds the entry once. Everything else in the policy keeps its value.
    static func apply(to policy: Data, target: String) throws -> Outcome {
        guard let root = (try? JSONSerialization.jsonObject(with: policy)) as? [String: Any] else {
            throw Failure.notPlainJSON
        }
        if allows(policy: policy, target: target) { return .alreadyAllowed }

        var updated = root
        switch root["nodeAttrs"] {
        case nil: updated["nodeAttrs"] = [entry(target: target)]
        case let list as [Any]: updated["nodeAttrs"] = list + [entry(target: target)]
        default: throw Failure.unexpectedShape
        }
        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return .updated(data)
    }
}

// MARK: - Credential

/// What the person pasted: an API access token, or the secret of an OAuth client.
enum TailscaleCredential: Equatable, Sendable {
    case accessToken(String)
    /// `secret` looks like `tskey-client-<id>-<rest>`. The client ID is the part after the prefix.
    case oauthClient(id: String, secret: String)

    static let oauthPrefix = "tskey-client-"

    /// Reads pasted text. Returns nil for empty text.
    init?(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(Self.oauthPrefix) {
            let rest = trimmed.dropFirst(Self.oauthPrefix.count)
            if let dash = rest.firstIndex(of: "-"), dash != rest.startIndex {
                self = .oauthClient(id: String(rest[..<dash]), secret: trimmed)
                return
            }
        }
        self = .accessToken(trimmed)
    }

    /// The text that goes in the Keychain.
    var stored: String {
        switch self {
        case .accessToken(let token): token
        case .oauthClient(_, let secret): secret
        }
    }
}

// MARK: - Storage

/// Raw secret bytes in one place. The Keychain is the real one; tests use memory.
protocol SecretBytesStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

final class InMemorySecretBytesStore: SecretBytesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(data: Data? = nil) { self.data = data }
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func delete() throws { lock.withLock { data = nil } }
}

/// A generic password in this app's Keychain.
struct KeychainSecretBytesStore: SecretBytesStore {
    static let tailscaleService = "iMCP Tailscale API token"

    let service: String
    let account: String

    init(service: String = Self.tailscaleService, account: String = "tailscale-api") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if KeychainClientRecordStorage.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainClientRecordStorage.Error.status(status) }
        guard let data = result as? Data else { throw KeychainClientRecordStorage.Error.status(errSecDecode) }
        return data
    }

    func write(_ data: Data) throws {
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

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainClientRecordStorage.Error.status(status)
        }
    }
}

/// Keeps the Tailscale credential in a secret store. Nothing here logs the value.
struct TailscaleCredentialVault: Sendable {
    let store: any SecretBytesStore

    init(store: any SecretBytesStore = KeychainSecretBytesStore()) {
        self.store = store
    }

    func load() throws -> TailscaleCredential? {
        guard let data = try store.read(), let text = String(data: data, encoding: .utf8) else { return nil }
        return TailscaleCredential(pasted: text)
    }

    @discardableResult
    func save(pasted text: String) throws -> TailscaleCredential? {
        guard let credential = TailscaleCredential(pasted: text) else { return nil }
        try store.write(Data(credential.stored.utf8))
        return credential
    }

    func remove() throws { try store.delete() }
}

// MARK: - Tailscale API

struct TailscalePolicySnapshot: Equatable, Sendable {
    let data: Data
    /// The `ETag` that Tailscale sent with it, quotes included.
    let etag: String
}

enum TailscaleAPIError: Error, Equatable, LocalizedError, Sendable {
    case rejectedCredential
    case missingPermission
    /// Someone saved the policy after iMCP read it.
    case policyChanged
    case invalidPolicy(String)
    case unexpected(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .rejectedCredential:
            "Tailscale did not accept this token. It may have expired or been revoked."
        case .missingPermission:
            "This token cannot read and change your Tailscale access controls. Create one with that permission."
        case .policyChanged:
            "Your Tailscale policy changed while you were looking. Nothing was saved. Try again."
        case .invalidPolicy(let message):
            "Tailscale did not accept the change: \(message)"
        case .unexpected(let status, let message):
            message.isEmpty ? "Tailscale answered with an error (HTTP \(status))." : "Tailscale said: \(message)"
        case .invalidResponse:
            "Tailscale sent an answer that iMCP could not read."
        }
    }
}

/// The two calls that iMCP needs. A fake stands in for them in tests.
protocol TailscalePolicyService: Sendable {
    func fetchPolicy() async throws -> TailscalePolicySnapshot
    /// Saves `policy` only if the stored policy still has the `etag` that was read.
    func replacePolicy(_ policy: Data, ifMatch etag: String) async throws
}

/// The Tailscale REST API: `GET` and `POST https://api.tailscale.com/api/v2/tailnet/-/acl`.
/// `-` is the tailnet that the credential belongs to.
struct TailscaleAPIClient: TailscalePolicyService {
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://api.tailscale.com/api/v2")!
    static let policyURL = baseURL.appending(path: "tailnet/-/acl")
    static let oauthTokenURL = baseURL.appending(path: "oauth/token")

    let credential: TailscaleCredential
    let transport: HTTPTransport

    init(
        credential: TailscaleCredential,
        transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.credential = credential
        self.transport = transport
    }

    func fetchPolicy() async throws -> TailscalePolicySnapshot {
        var request = URLRequest(url: Self.policyURL)
        request.httpMethod = "GET"
        // HuJSON keeps comments. The plain JSON answer would hide them, and iMCP must know.
        request.setValue("application/hujson", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        let (data, http) = try await send(request)
        try Self.check(http, data: data)
        guard let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw TailscaleAPIError.invalidResponse
        }
        return TailscalePolicySnapshot(data: data, etag: etag)
    }

    func replacePolicy(_ policy: Data, ifMatch etag: String) async throws {
        var request = URLRequest(url: Self.policyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = policy
        let (data, http) = try await send(request)
        try Self.check(http, data: data)
    }

    // MARK: Private

    private func bearer() async throws -> String {
        switch credential {
        case .accessToken(let token): return token
        case .oauthClient(let id, let secret): return try await exchange(id: id, secret: secret)
        }
    }

    /// Trades an OAuth client for a short-lived access token that can edit the policy file.
    private func exchange(id: String, secret: String) async throws -> String {
        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "client_secret", value: secret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "scope", value: "policy_file"),
        ]
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }
        let (data, http) = try await send(request)
        if http.statusCode == 400 || http.statusCode == 401 { throw TailscaleAPIError.rejectedCredential }
        try Self.check(http, data: data)
        struct Answer: Decodable { let access_token: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), !answer.access_token.isEmpty else {
            throw TailscaleAPIError.invalidResponse
        }
        return answer.access_token
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw TailscaleAPIError.invalidResponse }
        return (data, http)
    }

    /// Maps a failed answer to a reason. The message is Tailscale's, never the request.
    static func check(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200 ..< 300).contains(http.statusCode) else { return }
        struct Failure: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message ?? ""
        switch http.statusCode {
        case 401: throw TailscaleAPIError.rejectedCredential
        case 403: throw TailscaleAPIError.missingPermission
        case 412: throw TailscaleAPIError.policyChanged
        case 400: throw TailscaleAPIError.invalidPolicy(message.isEmpty ? "the policy was not valid" : message)
        default: throw TailscaleAPIError.unexpected(status: http.statusCode, message: message)
        }
    }
}

// MARK: - Controller

/// The "Let iMCP turn this on for me" flow: read the policy, show the change, apply it on a confirmation,
/// then read it back to check.
@MainActor
final class TailscaleAccessController: ObservableObject {
    /// What will change, ready to show.
    struct Plan: Equatable {
        let target: String
        let newPolicy: Data
        let etag: String
        /// One plain line.
        var summary: String { "Allow public addresses for this Mac." }
        var entryText: String { TailscalePolicyEdit.entryText(target: target) }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        /// Waiting for the person to confirm.
        case review(Plan)
        case done
        /// Nothing to change: the policy already allows it.
        case alreadyAllowed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasCredential: Bool

    private let vault: TailscaleCredentialVault
    private let makeService: @Sendable (TailscaleCredential) -> any TailscalePolicyService
    private let log = Logger(subsystem: "co.dododo.iMCP", category: "tailscale.policy")

    init(
        vault: TailscaleCredentialVault = TailscaleCredentialVault(),
        makeService: @escaping @Sendable (TailscaleCredential) -> any TailscalePolicyService = {
            TailscaleAPIClient(credential: $0)
        }
    ) {
        self.vault = vault
        self.makeService = makeService
        self.hasCredential = ((try? vault.load()) ?? nil) != nil
    }

    /// Saves what the person pasted, then reads the policy and shows the change.
    func useCredential(_ pasted: String, target: String) async {
        do {
            guard try vault.save(pasted: pasted) != nil else {
                phase = .failed("Paste a Tailscale access token first.")
                return
            }
            hasCredential = true
        } catch {
            phase = .failed("iMCP could not save the token in the Keychain.")
            return
        }
        await prepare(target: target)
    }

    /// Reads the policy and works out the change. Nothing is written.
    func prepare(target: String) async {
        guard let credential = try? vault.load() else {
            hasCredential = false
            phase = .failed("Paste a Tailscale access token first.")
            return
        }
        phase = .working("Reading your Tailscale policy…")
        do {
            let snapshot = try await makeService(credential).fetchPolicy()
            switch try TailscalePolicyEdit.apply(to: snapshot.data, target: target) {
            case .alreadyAllowed: phase = .alreadyAllowed
            case .updated(let data): phase = .review(Plan(target: target, newPolicy: data, etag: snapshot.etag))
            }
        } catch {
            fail(error)
        }
    }

    /// Writes the reviewed change, then reads the policy again to confirm it took.
    func confirm() async {
        guard case .review(let plan) = phase, let credential = try? vault.load() else { return }
        phase = .working("Saving…")
        let service = makeService(credential)
        do {
            try await service.replacePolicy(plan.newPolicy, ifMatch: plan.etag)
            let again = try await service.fetchPolicy()
            guard TailscalePolicyEdit.allows(policy: again.data, target: plan.target) else {
                phase = .failed("Tailscale saved the policy but the change is not in it. Check the Tailscale page.")
                return
            }
            phase = .done
        } catch {
            fail(error)
        }
    }

    func cancelReview() { phase = .idle }

    func removeCredential() {
        try? vault.remove()
        hasCredential = false
        phase = .idle
    }

    private func fail(_ error: Error) {
        // The reason is Tailscale's or ours. The credential is never part of it.
        log.error("Tailscale policy step failed: \(error.localizedDescription, privacy: .public)")
        phase = .failed(error.localizedDescription)
    }
}
