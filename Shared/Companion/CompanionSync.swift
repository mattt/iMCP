import CryptoKit
import Foundation

// Types that the iPhone companion and the Mac exchange.
// This file uses only Foundation and CryptoKit,
// so the FinanceKit background delivery extension can compile it.

/// A group of companion tools that the user turns on separately.
enum CompanionDomain: String, CaseIterable, Codable, Sendable {
    case health
    case finance
    case alarms
}

/// The kinds of data that the phone sends to the Mac's cache.
enum CompanionKind: String, Codable, CaseIterable, Sendable {
    case healthSample = "health.sample"
    case healthStatistic = "health.statistic"
    case workout = "health.workout"
    case clinicalRecord = "health.clinical"
    case account = "finance.account"
    case balance = "finance.balance"
    case transaction = "finance.transaction"
    case alarm = "alarm"

    var domain: CompanionDomain {
        switch self {
        case .healthSample, .healthStatistic, .workout, .clinicalRecord: return .health
        case .account, .balance, .transaction: return .finance
        case .alarm: return .alarms
        }
    }
}

/// One object to store on the Mac, or the deletion of one.
///
/// `key` is what queries filter on:
/// the HealthKit type name, workout activity type, or FinanceKit account ID.
/// `payload` is the JSON object that tools return, or nil for a deletion.
struct CompanionRecord: Codable, Equatable, Sendable {
    var kind: CompanionKind
    var id: String
    var key: String?
    var start: Date?
    var end: Date?
    var payload: Data?

    var isDeletion: Bool { payload == nil }

    static func deletion(kind: CompanionKind, id: String) -> CompanionRecord {
        CompanionRecord(kind: kind, id: id, key: nil, start: nil, end: nil, payload: nil)
    }
}

/// Records that the phone has queued, in the order it queued them.
///
/// The Mac applies a batch in one transaction and then acknowledges `sequence`,
/// so the phone can drop the batch.
/// Applying a batch twice has the same result as applying it once.
struct CompanionBatch: Codable, Equatable, Sendable {
    var sequence: Int64
    /// When the phone collected each domain's data, keyed by `CompanionDomain` raw value.
    var syncedAt: [String: Date]
    var records: [CompanionRecord]
    /// Kinds whose records this batch replaces in full, such as the alarm list.
    var replacing: [CompanionKind] = []
    /// Whether the phone has more batches queued.
    var hasMore = false
}

/// JSON coding for messages between the phone and the Mac.
enum CompanionCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Encodes a JSON object for a record payload, with ISO 8601 dates.
    static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// An ISO 8601 timestamp with milliseconds.
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Link

/// Constants and messages for the connection between the phone and the Mac.
///
/// The Mac advertises a Bonjour service and listens with TLS that uses pre-shared keys.
/// The phone connects, proves that it holds a pairing secret or a device key,
/// and then serves MCP on the same connection,
/// so the Mac acts as the MCP client even though the phone dialed in.
enum CompanionLink {
    static let serviceType = "_imcp-companion._tcp"
    static let protocolVersion = 1
    /// Tools that the Mac calls on the phone to move queued records.
    /// They aren't part of the tool list that MCP clients see.
    static let pullTool = "companion_sync_pull"
    static let ackTool = "companion_sync_ack"
    static let serverName = "iMCP Companion"

    static func pairingIdentity(_ pairingID: String) -> Data { Data("pair:\(pairingID)".utf8) }
    static func deviceIdentity(_ deviceID: String) -> Data { Data("device:\(deviceID)".utf8) }

    /// The TLS key for a pairing secret from the QR code.
    static func pairingKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            info: Data("imcp-companion-pairing-psk".utf8),
            outputByteCount: 32
        )
    }

    /// Proof that the sender holds `key`, bound to the device and the purpose.
    static func proof(key: SymmetricKey, device: String, purpose: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(purpose)|\(device)".utf8), using: key)
        return Data(code).base64EncodedString()
    }

    static func verify(_ proof: String, key: SymmetricKey, device: String, purpose: String) -> Bool {
        guard let data = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            data,
            authenticating: Data("\(purpose)|\(device)".utf8),
            using: key
        )
    }
}

/// The first message on a connection, from the phone.
struct CompanionHello: Codable, Equatable, Sendable {
    var version: Int
    var device: String
    var name: String
    /// Present when pairing: the pairing ID from the QR code.
    var pairing: String?
    var proof: String
    /// Asks the Mac to forget this device, with a proof for the purpose `revoke`.
    var revoke: Bool?
}

/// The Mac's reply. When pairing succeeds, it carries the device key.
struct CompanionWelcome: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?
    var mac: String?
    var deviceKey: Data?
}

/// What the QR code on the Mac carries.
struct CompanionPairingCode: Equatable, Sendable {
    var service: String
    var pairingID: String
    var secret: Data

    var url: URL {
        var components = URLComponents()
        components.scheme = "imcp-companion"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(CompanionLink.protocolVersion)),
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "id", value: pairingID),
            URLQueryItem(name: "secret", value: secret.base64URLEncodedString()),
        ]
        return components.url!
    }

    init(service: String, pairingID: String, secret: Data) {
        self.service = service
        self.pairingID = pairingID
        self.secret = secret
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "imcp-companion", components.host == "pair"
        else { return nil }
        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard items["v"] == String(CompanionLink.protocolVersion),
            let service = items["service"], !service.isEmpty,
            let pairingID = items["id"], !pairingID.isEmpty,
            let secret = items["secret"].flatMap(Data.init(base64URLEncoded:)), secret.count >= 16
        else { return nil }
        self.init(service: service, pairingID: pairingID, secret: secret)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
