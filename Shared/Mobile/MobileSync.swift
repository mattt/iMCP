import CryptoKit
import Foundation

// Types that iMCP on iOS and on the Mac exchange.
// This file uses only Foundation and CryptoKit,
// so the FinanceKit background delivery extension can compile it.

/// A group of mobile tools that the user turns on separately.
enum MobileDomain: String, CaseIterable, Codable, Sendable {
    case health
    case finance
    case alarms
}

/// The kinds of data that the phone sends to the Mac's cache.
enum MobileKind: String, Codable, CaseIterable, Sendable {
    case healthSample = "health.sample"
    case healthStatistic = "health.statistic"
    case workout = "health.workout"
    case clinicalRecord = "health.clinical"
    case account = "finance.account"
    case balance = "finance.balance"
    case transaction = "finance.transaction"
    case alarm = "alarm"

    var domain: MobileDomain {
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
struct MobileRecord: Codable, Equatable, Sendable {
    var kind: MobileKind
    var id: String
    var key: String?
    var start: Date?
    var end: Date?
    var payload: Data?

    var isDeletion: Bool { payload == nil }

    static func deletion(kind: MobileKind, id: String) -> MobileRecord {
        MobileRecord(kind: kind, id: id, key: nil, start: nil, end: nil, payload: nil)
    }
}

/// Records that the phone has queued, in the order it queued them.
///
/// The Mac applies a batch in one transaction and then acknowledges `sequence`,
/// so the phone can drop the batch.
/// Applying a batch twice has the same result as applying it once.
struct MobileBatch: Codable, Equatable, Sendable {
    var sequence: Int64
    /// When the phone collected each domain's data, keyed by `MobileDomain` raw value.
    var syncedAt: [String: Date]
    var records: [MobileRecord]
    /// Kinds whose records this batch replaces in full, such as the alarm list.
    var replacing: [MobileKind] = []
    /// Whether the phone has more batches queued.
    var hasMore = false
}

/// JSON coding for messages between the phone and the Mac.
enum MobileCoding {
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
enum MobileLink {
    static let serviceType = "_imcp-mobile._tcp"
    static let protocolVersion = 1
    /// Tools that the Mac calls on the phone to move queued records.
    /// They aren't part of the tool list that MCP clients see.
    static let pullTool = "mobile_sync_pull"
    static let ackTool = "mobile_sync_ack"
    static let serverName = "iMCP iOS"

    static func pairingIdentity(_ pairingID: String) -> Data { Data("pair:\(pairingID)".utf8) }
    static func deviceIdentity(_ deviceID: String) -> Data { Data("device:\(deviceID)".utf8) }

    /// The TLS key for a pairing secret from the QR code.
    static func pairingKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            info: Data("imcp-mobile-pairing-psk".utf8),
            outputByteCount: 32
        )
    }

    /// Proof that the sender holds `key`, bound to the device, the purpose,
    /// and `context`, such as the public keys of a pairing exchange.
    static func proof(key: SymmetricKey, device: String, purpose: String, context: Data = Data()) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: message(device, purpose, context), using: key)
        return Data(code).base64EncodedString()
    }

    static func verify(
        _ proof: String,
        key: SymmetricKey,
        device: String,
        purpose: String,
        context: Data = Data()
    ) -> Bool {
        guard let data = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            data,
            authenticating: message(device, purpose, context),
            using: key
        )
    }

    private static func message(_ device: String, _ purpose: String, _ context: Data) -> Data {
        Data("\(purpose)|\(device)|\(context.base64EncodedString())".utf8)
    }
}

/// The key exchange that gives a newly paired iPhone or iPad its device key.
///
/// Each side sends a one-time X25519 public key,
/// and both derive the device key from the shared secret, salted with the pairing key.
/// The device key never crosses the network,
/// so someone who saw the QR code and recorded the pairing can't learn it.
/// Each side's proof covers the public keys, so neither key can be swapped.
enum MobileKeyExchange {
    static func deviceKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peer: Data,
        pairingKey: SymmetricKey,
        device: String,
        phone: Data,
        mac: Data
    ) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        )
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingKey.withUnsafeBytes { Data($0) },
            sharedInfo: Data("imcp-mobile-device-key|\(device)|".utf8) + phone + mac,
            outputByteCount: 32
        )
    }

    /// The Mac's proof that it holds the pairing key and chose `mac` for this phone.
    static func welcomeProof(
        pairingKey: SymmetricKey,
        pairingID: String,
        device: String,
        phone: Data,
        mac: Data
    ) -> String {
        MobileLink.proof(key: pairingKey, device: device, purpose: "welcome:\(pairingID)", context: phone + mac)
    }
}

/// The first message on a connection, from the phone.
struct MobileHello: Codable, Equatable, Sendable {
    var version: Int
    var device: String
    var name: String
    /// Present when pairing: the pairing ID from the QR code.
    var pairing: String?
    var proof: String
    /// Asks the Mac to forget this device, with a proof for the purpose `revoke`.
    var revoke: Bool?
    /// When pairing: the phone's one-time X25519 public key, which `proof` covers.
    var exchange: Data?
}

/// The Mac's reply. When pairing succeeds, it carries the Mac's half of the key exchange.
struct MobileWelcome: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String? = nil
    var mac: String? = nil
    /// When pairing: the Mac's one-time X25519 public key.
    var exchange: Data? = nil
    /// When pairing: the Mac's proof that it holds the pairing key, covering both public keys.
    var proof: String? = nil
}

/// What the QR code on the Mac carries.
struct MobilePairingCode: Equatable, Sendable {
    var service: String
    var pairingID: String
    var secret: Data

    var url: URL {
        var components = URLComponents()
        components.scheme = "imcp"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(MobileLink.protocolVersion)),
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
            components.scheme == "imcp", components.host == "pair"
        else { return nil }
        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard items["v"] == String(MobileLink.protocolVersion),
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
