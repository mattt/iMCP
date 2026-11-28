import CryptoKit
import Foundation
import OSLog
import Security

/// A secret that iMCP issues to one MCP client.
///
/// A client presents its credential through `imcp-server`,
/// which reads it from the ``environmentVariable`` environment variable
/// in the client's MCP server settings.
/// iMCP stores only the credential's ``identifier(for:)``,
/// a SHA-256 hash, so the credential itself can't be read back from iMCP.
enum ClientCredential {
    /// The environment variable that `imcp-server` reads the credential from.
    static let environmentVariable = LocalSocketHello.credentialEnvironmentVariable

    static let prefix = "imcp_"
    static let secretByteCount = 32

    /// Returns a new credential with 256 random bits.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return prefix + base64URLEncoded(Data(bytes))
    }

    /// Returns the identifier that iMCP stores for `credential`,
    /// or `nil` if `credential` isn't in the format that ``generate()`` returns.
    static func identifier(for credential: String) -> String? {
        guard credential.hasPrefix(prefix),
            let secret = base64URLDecoded(String(credential.dropFirst(prefix.count))),
            secret.count == secretByteCount
        else { return nil }

        return SHA256.hash(data: Data(credential.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The name that a client reports, made safe to show.
enum ClientName {
    /// The most characters of a reported name that iMCP shows.
    static let maximumLength = 64

    /// The name to show when a client reports an empty name.
    static let unnamed = "Unnamed Client"

    /// Returns `name` on one line, without control or invisible formatting characters,
    /// such as bidirectional overrides, and at most ``maximumLength`` characters long.
    ///
    /// A client chooses its name freely,
    /// so it could otherwise imitate other text in the approval dialog.
    static func sanitized(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        guard !line.isEmpty else { return unnamed }
        guard line.count > maximumLength else { return line }
        return line.prefix(maximumLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What iMCP stores about a client that it trusts:
/// a credential that it issued, or a code signature.
struct ClientRecord: Codable, Equatable, Identifiable, Sendable {
    /// For a credential, its identifier, from ``ClientCredential/identifier(for:)``.
    /// For a signature, ``id(for:)``.
    var id: String
    /// The client name to show for the record.
    /// For a record made from the approval dialog,
    /// this is the name that the client reported when the person approved it.
    var name: String
    /// When iMCP issued the credential or trusted the signature.
    var issuedAt: Date
    /// Whether the client connects without an approval dialog.
    ///
    /// iMCP issues an untrusted credential when it writes a client's settings,
    /// so that the first approval can apply to that credential.
    var isTrusted: Bool
    /// The signing identity that the record trusts, or `nil` for a credential.
    ///
    /// The identity has no path or code hash, so it keeps working when the client updates.
    var signature: ClientSignature?

    /// Returns the record identifier for a signing identity.
    ///
    /// A credential's identifier is a hexadecimal hash, so the two kinds can't collide.
    static func id(for signature: ClientSignature) -> String {
        "signature:\(signature.team):\(signature.identifier)"
    }
}

/// Persistent storage for ``ClientRecord`` values.
protocol ClientRecordStorage {
    func loadAll() throws -> [ClientRecord]
    func save(_ record: ClientRecord) throws
    func delete(id: String) throws
    func deleteAll() throws
}

/// Stores client records in memory, for tests.
final class InMemoryClientRecordStorage: ClientRecordStorage {
    var records: [String: ClientRecord] = [:]
    var error: (any Error)?

    func loadAll() throws -> [ClientRecord] {
        if let error { throw error }
        return Array(records.values)
    }

    func save(_ record: ClientRecord) throws {
        if let error { throw error }
        records[record.id] = record
    }

    func delete(id: String) throws {
        if let error { throw error }
        records.removeValue(forKey: id)
    }

    func deleteAll() throws {
        if let error { throw error }
        records.removeAll()
    }
}

/// Stores client records as generic password items in the Keychain.
///
/// Release builds use the data protection keychain,
/// where the items belong to the app's access group
/// and other apps can't read, add, or change them.
/// Each item holds a record in its attributes and no secret data;
/// the credential itself isn't stored.
struct KeychainClientRecordStorage: ClientRecordStorage {
    enum Error: Swift.Error, CustomStringConvertible {
        case status(OSStatus)

        var description: String {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "\(message) (\(status))"
            }
        }
    }

    var service = "\(Bundle.main.bundleIdentifier ?? LocalSocket.appBundleIdentifier).client-credentials"

    /// Whether to use the data protection keychain.
    ///
    /// An unsigned Debug build has no application identifier,
    /// so the data protection keychain refuses it with `errSecMissingEntitlement`.
    /// Debug builds then fall back to the login keychain.
    /// Release builds don't contain the fallback.
    static let usesDataProtectionKeychain: Bool = {
        #if DEBUG
            // The login keychain doesn't limit items to this app:
            // any process that runs as the same user can add a record there,
            // including a trusted one, so a Debug build's trust protects nothing.
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain: true,
                kSecAttrService: "\(LocalSocket.appBundleIdentifier).entitlement-check",
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
        #else
            return true
        #endif
    }()

    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if Self.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    func loadAll() throws -> [ClientRecord] {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Error.status(status) }

        let items = result as? [[CFString: Any]] ?? []
        let decoder = JSONDecoder()
        return items.compactMap { item in
            guard let data = item[kSecAttrGeneric] as? Data else { return nil }
            return try? decoder.decode(ClientRecord.self, from: data)
        }
    }

    func save(_ record: ClientRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)

        var item = baseQuery
        item[kSecAttrAccount] = record.id

        let attributes: [CFString: Any] = [
            kSecAttrGeneric: data,
            kSecAttrLabel: "iMCP client: \(record.name)",
        ]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(attributes) { $1 }
            if Self.usesDataProtectionKeychain {
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    func delete(id: String) throws {
        var query = baseQuery
        query[kSecAttrAccount] = id
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.status(status) }
    }

    func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.status(status) }
    }
}

/// The open connections that each client record let in or was issued to.
///
/// Revoking a credential or a trusted signature stops it from approving new connections,
/// and this record lets iMCP close the connections that it already approved.
/// The `credentialID` of a signature is its record identifier.
struct CredentialSessions: Equatable {
    private(set) var connections: [String: Set<UUID>] = [:]

    /// Records that `connectionID` presented, or was issued, the credential with `credentialID`.
    mutating func add(_ connectionID: UUID, credentialID: String) {
        connections[credentialID, default: []].insert(connectionID)
    }

    /// Forgets a connection that closed.
    mutating func remove(_ connectionID: UUID) {
        for (credentialID, var ids) in connections where ids.contains(connectionID) {
            ids.remove(connectionID)
            connections[credentialID] = ids.isEmpty ? nil : ids
        }
    }

    /// Forgets the credential with `credentialID` and returns its connections to close.
    mutating func revoke(credentialID: String) -> Set<UUID> {
        connections.removeValue(forKey: credentialID) ?? []
    }

    /// Forgets every credential and returns all their connections to close.
    mutating func revokeAll() -> Set<UUID> {
        defer { connections.removeAll() }
        return connections.values.reduce(into: []) { $0.formUnion($1) }
    }
}

/// Issues, checks, and revokes client credentials, trusts clients by their code signatures,
/// and tracks clients that were trusted by name before credentials.
@MainActor
final class ClientCredentialStore {
    /// The `UserDefaults` key where earlier versions stored the names of trusted clients.
    static let legacyTrustedClientsKey = "trustedClients"

    private let storage: any ClientRecordStorage
    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var records: [String: ClientRecord] = [:]

    init(
        storage: any ClientRecordStorage,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.defaults = defaults
        self.now = now
        reload()
    }

    /// Reads the records from storage again.
    func reload() {
        do {
            records = Dictionary(try storage.loadAll().map { ($0.id, $0) }) { first, _ in first }
        } catch {
            Logger.server.error("Failed to load client credentials: \(String(describing: error), privacy: .public)")
            records = [:]
        }
    }

    /// The trusted clients, sorted by name.
    var trustedRecords: [ClientRecord] {
        records.values
            .filter(\.isTrusted)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns the record for `credential`, if iMCP issued it and hasn't revoked it.
    func record(for credential: String?) -> ClientRecord? {
        guard let credential, let id = ClientCredential.identifier(for: credential) else { return nil }
        return records[id]
    }

    /// Returns the record that trusts `signature`, if the person trusts the client by its signature.
    func record(for signature: ClientSignature) -> ClientRecord? {
        guard let record = records[ClientRecord.id(for: signature)], record.isTrusted,
            let trusted = record.signature,
            trusted.identifier == signature.identifier, trusted.team == signature.team
        else { return nil }
        return record
    }

    /// Stores a record that trusts `signature`.
    func trust(_ signature: ClientSignature, name: String) throws -> ClientRecord {
        let record = ClientRecord(
            id: ClientRecord.id(for: signature),
            name: name,
            issuedAt: now(),
            isTrusted: true,
            signature: signature
        )
        try storage.save(record)
        records[record.id] = record
        return record
    }

    /// Issues a credential and stores its record.
    ///
    /// - Returns: The credential, which iMCP can't show again,
    ///   and the stored record.
    func issue(name: String, trusted: Bool) throws -> (credential: String, record: ClientRecord) {
        let credential = ClientCredential.generate()
        guard let id = ClientCredential.identifier(for: credential) else {
            preconditionFailure("A generated credential has an identifier")
        }
        let record = ClientRecord(id: id, name: name, issuedAt: now(), isTrusted: trusted)
        try storage.save(record)
        records[id] = record
        return (credential, record)
    }

    /// Marks the record with `id` as trusted.
    func trust(id: String) throws {
        guard var record = records[id] else { return }
        record.isTrusted = true
        try storage.save(record)
        records[id] = record
    }

    /// Deletes the record with `id`, so that its credential stops working.
    func revoke(id: String) throws {
        try storage.delete(id: id)
        records.removeValue(forKey: id)
    }

    /// Deletes every record and every name from earlier versions.
    func revokeAll() throws {
        try storage.deleteAll()
        records.removeAll()
        defaults.removeObject(forKey: Self.legacyTrustedClientsKey)
    }

    // MARK: - Trust by name

    /// The names of clients that earlier versions trusted by name.
    ///
    /// These names no longer approve a connection.
    /// iMCP keeps them only to tell the person
    /// that a client needs to be approved again.
    var legacyTrustedNames: [String] {
        guard let data = defaults.data(forKey: Self.legacyTrustedClientsKey),
            let names = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Forgets that an earlier version trusted `name`.
    func removeLegacyTrustedName(_ name: String) {
        var names = Set(legacyTrustedNames)
        guard names.remove(name) != nil else { return }
        if names.isEmpty {
            defaults.removeObject(forKey: Self.legacyTrustedClientsKey)
        } else if let data = try? JSONEncoder().encode(names) {
            defaults.set(data, forKey: Self.legacyTrustedClientsKey)
        }
    }

    // MARK: - Approval

    /// What iMCP knows about a connection that asks for approval.
    struct Request: Equatable {
        /// The name that the client reported, which it can choose freely,
        /// after ``ClientName/sanitized(_:)``.
        var claimedName: String
        /// The record for the credential that the connection presented.
        var record: ClientRecord?
        /// Whether the connection presented a credential that iMCP doesn't recognize.
        var hasUnrecognizedCredential: Bool
        /// Whether an earlier version trusted a client with the claimed name.
        var wasTrustedByName: Bool
        /// What iMCP found out about the client's code signature.
        var verification: ClientVerification = .unidentified

        /// The client whose signature iMCP verified, if it passes every check.
        var verifiedClient: VerifiedClient? {
            verification.verifiedClient
        }

        /// The key that identifies the client, or `nil` if nothing does.
        ///
        /// A verified signature identifies the client first, then a recognized credential.
        private var clientKey: String? {
            if let verifiedClient { return ClientRecord.id(for: verifiedClient.signature) }
            if let record { return "credential:\(record.id)" }
            return nil
        }

        /// The key for coalescing approval dialogs.
        ///
        /// Connections with the same verified signature, or else the same credential, share a dialog.
        /// Other connections each get their own,
        /// because nothing shows that they come from the same client.
        func approvalKey(connectionID: UUID) -> String {
            clientKey ?? "connection:\(connectionID.uuidString)"
        }

        /// The key for refusing requests for a while after a denial,
        /// or `nil` if nothing identifies the client.
        ///
        /// A client without a recognized credential or a verified signature gets no cooldown.
        /// Its claimed name can't key one:
        /// a client could change its name to evade a cooldown,
        /// or claim another client's name to lock that client out.
        /// The limits on open and waiting requests bound such clients instead.
        var cooldownKey: String? {
            clientKey
        }

        /// Why iMCP can't trust the client by its signature, in one line,
        /// or `nil` if the client passes every check.
        var signatureNote: String? {
            switch verification {
            case .verified:
                return nil
            case .failed(let failure):
                return failure.message
            case .unidentified:
                return "iMCP can't tell which app started this connection, so it can't check a signature."
            }
        }

        /// A warning for a verified client that runs for whatever process starts it, or `nil`.
        ///
        /// A command-line tool, such as Claude Code, runs the MCP servers that it's told to run,
        /// so trusting its signature trusts every app that can start it.
        var sharedAccessNote: String? {
            guard let verifiedClient, !verifiedClient.isApplication else { return nil }
            return
                "Any app on this Mac that can start \(verifiedClient.signature.identifier) can use iMCP through it."
        }

        /// What iMCP knows about the client beyond the name it reported.
        var identityNote: String {
            if let verifiedClient {
                let signature = verifiedClient.signature
                return
                    "Signed by \(signature.publisherDescription) as \(signature.identifier). It reports the name \"\(claimedName)\"."
            }
            if let record {
                let date = record.issuedAt.formatted(date: .abbreviated, time: .omitted)
                return "This client uses the credential that iMCP created for \"\(record.name)\" on \(date)."
            }
            if hasUnrecognizedCredential {
                return "This client presented a credential that iMCP didn't create or has removed."
            }
            let note = "This client presented no credential, so any app could have sent this name."
            if wasTrustedByName {
                return note
                    + " You trusted a client with this name before. iMCP now trusts clients by credential instead of by name."
            }
            return note
        }
    }

    enum Decision: Equatable {
        /// The credential or the signature is trusted, so the connection is approved without a dialog.
        case approve(ClientRecord)
        /// The person decides.
        case ask(Request)
    }

    /// Decides whether a connection needs approval.
    ///
    /// A trusted credential approves a connection first,
    /// then a verified signature that the person trusts.
    /// The claimed name never does, even if an earlier version trusted it.
    func evaluate(
        credential: String?,
        verification: ClientVerification = .unidentified,
        claimedName reportedName: String
    ) -> Decision {
        let claimedName = ClientName.sanitized(reportedName)
        let record = record(for: credential)
        if let record, record.isTrusted {
            return .approve(record)
        }
        if let client = verification.verifiedClient, let trusted = self.record(for: client.signature) {
            return .approve(trusted)
        }
        return .ask(
            Request(
                claimedName: claimedName,
                record: record,
                hasUnrecognizedCredential: credential != nil && record == nil,
                wasTrustedByName: legacyTrustedNames.contains(claimedName),
                verification: verification
            )
        )
    }

    /// The result of ``alwaysTrust(_:)``.
    struct Trust: Equatable {
        /// The record that now approves the client.
        var record: ClientRecord
        /// A new credential for the person to add to the client's settings, if iMCP issued one.
        var credential: String?
    }

    /// Records that the person approved `request` and chose to always trust the client.
    ///
    /// If the client passes the signature checks, iMCP trusts its signature.
    /// Otherwise, if the connection presented a credential that iMCP issued,
    /// that credential becomes trusted.
    /// Otherwise iMCP issues a trusted credential
    /// for the person to add to the client's settings.
    func alwaysTrust(_ request: Request) throws -> Trust {
        removeLegacyTrustedName(request.claimedName)
        if let client = request.verifiedClient {
            return Trust(record: try trust(client.signature, name: request.claimedName))
        }
        if let record = request.record {
            try trust(id: record.id)
            return Trust(record: records[record.id] ?? record)
        }
        let (credential, record) = try issue(name: request.claimedName, trusted: true)
        return Trust(record: record, credential: credential)
    }

    /// Returns a credential to write into a client's settings.
    ///
    /// If `existing` is a credential that iMCP issued, it's returned unchanged,
    /// so that writing the settings again keeps the client's trust.
    /// Otherwise iMCP issues an untrusted credential named `name`.
    func credentialForSettings(name: String, existing: String?) throws -> String {
        if let existing, record(for: existing) != nil {
            return existing
        }
        return try issue(name: name, trusted: false).credential
    }
}
