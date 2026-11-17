import CryptoKit
import Foundation

// Types that iMCP on iOS and on the Mac exchange.
// This file uses only Foundation and CryptoKit,
// so that app extensions can compile it.

/// A group of mobile tools that the user turns on separately.
enum MobileDomain: String, CaseIterable, Codable, Sendable {
    case health
    case alarms
}

/// The kinds of data that the phone sends to the Mac's cache.
enum MobileKind: String, Codable, CaseIterable, Sendable {
    case healthSample = "health.sample"
    case healthStatistic = "health.statistic"
    case workout = "health.workout"
    case clinicalRecord = "health.clinical"
    case alarm = "alarm"

    var domain: MobileDomain {
        switch self {
        case .healthSample, .healthStatistic, .workout, .clinicalRecord: return .health
        case .alarm: return .alarms
        }
    }
}

/// One object to store on the Mac, or the deletion of one.
///
/// `key` is what queries filter on:
/// the HealthKit type name or workout activity type.
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
    static let defaultRemotePort: UInt16 = 4628
    static let defaultWebSocketPort: UInt16 = 4629
    static let mobileWebSocketPath = "/mobile"
    /// Tools that the Mac calls on the phone to move queued records.
    /// They aren't part of the tool list that MCP clients see.
    static let pullTool = "mobile_sync_pull"
    static let ackTool = "mobile_sync_ack"
    static let serverName = "iMCP iOS"

    static func pairingIdentity(_ pairingID: String) -> Data { Data("pair:\(pairingID)".utf8) }
    static func deviceIdentity(_ deviceID: String) -> Data { Data("device:\(deviceID)".utf8) }

    /// Normalizes a user-entered WebSocket endpoint URL for Tailscale Funnel or Cloudflare Tunnel.
    /// Accepts `wss://...`, `ws://...`, `https://...`, `http://...`, or a bare hostname,
    /// and ensures the path defaults to `/mobile` when empty or `/`.
    static func normalizedWebSocketURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "wss://\(trimmed)"
        }
        guard var components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty
        else { return nil }
        switch scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": components.scheme = scheme
        default: return nil
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = mobileWebSocketPath
        }
        return components.string
    }

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

    enum Role: Sendable {
        case phone
        case mac
    }

    /// Derives directional ChaCha20-Poly1305 session keys for app-layer encrypted WebSocket channels.
    static func sessionKeys(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peer: Data,
        psk: SymmetricKey,
        device: String,
        phone: Data,
        mac: Data,
        role: Role
    ) throws -> (send: SymmetricKey, receive: SymmetricKey) {
        let shared = try privateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        )
        let salt = psk.withUnsafeBytes { Data($0) }
        let context = Data("imcp-mobile-ws-v1|\(device)|".utf8) + phone + mac
        let phoneToMac = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context + Data("|c2s".utf8),
            outputByteCount: 32
        )
        let macToPhone = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context + Data("|s2c".utf8),
            outputByteCount: 32
        )
        switch role {
        case .phone: return (phoneToMac, macToPhone)
        case .mac: return (macToPhone, phoneToMac)
        }
    }
}

/// How the iPhone or iPad connects to the Mac.
enum MobileTransportMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case localOnly
    case tailscaleVPN
    case tailscaleFunnel
    case cloudflare

    var label: String {
        switch self {
        case .automatic: return "Automatic (Local Network, Tailscale, Cloudflare)"
        case .localOnly: return "Local Network (Bonjour)"
        case .tailscaleVPN: return "Tailscale VPN"
        case .tailscaleFunnel: return "Tailscale Funnel"
        case .cloudflare: return "Cloudflare Tunnel"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic: return "Automatic"
        case .localOnly: return "Local Network"
        case .tailscaleVPN: return "Tailscale VPN"
        case .tailscaleFunnel: return "Tailscale Funnel"
        case .cloudflare: return "Cloudflare Tunnel"
        }
    }
}

/// A concrete transport endpoint to dial.
enum MobileTransportCandidate: Equatable, Sendable {
    case bonjour(service: String)
    case tailscaleVPN(host: String, port: UInt16)
    case tailscaleFunnel(url: URL)
    case cloudflare(url: URL)

    var mode: MobileTransportMode {
        switch self {
        case .bonjour: return .localOnly
        case .tailscaleVPN: return .tailscaleVPN
        case .tailscaleFunnel: return .tailscaleFunnel
        case .cloudflare: return .cloudflare
        }
    }
}

extension MobileTransportMode {
    /// Returns the ordered list of endpoints to try for this mode.
    func candidates(
        service: String,
        tailnetHost: String?,
        tailnetPort: UInt16?,
        funnelURL: String?,
        cloudflareURL: String?
    ) -> [MobileTransportCandidate] {
        let trimmedHost = tailnetHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        let effectivePort = (tailnetPort ?? 0) > 0 ? tailnetPort! : MobileLink.defaultRemotePort
        let parsedFunnel = MobileLink.normalizedWebSocketURL(funnelURL).flatMap(URL.init(string:))
        let parsedCloudflare = MobileLink.normalizedWebSocketURL(cloudflareURL).flatMap(URL.init(string:))

        switch self {
        case .localOnly:
            return [.bonjour(service: service)]
        case .tailscaleVPN:
            guard let validHost else { return [] }
            return [.tailscaleVPN(host: validHost, port: effectivePort)]
        case .tailscaleFunnel:
            guard let parsedFunnel else { return [] }
            return [.tailscaleFunnel(url: parsedFunnel)]
        case .cloudflare:
            guard let parsedCloudflare else { return [] }
            return [.cloudflare(url: parsedCloudflare)]
        case .automatic:
            var list: [MobileTransportCandidate] = [.bonjour(service: service)]
            if let validHost {
                list.append(.tailscaleVPN(host: validHost, port: effectivePort))
            }
            if let parsedFunnel {
                list.append(.tailscaleFunnel(url: parsedFunnel))
            }
            if let parsedCloudflare {
                list.append(.cloudflare(url: parsedCloudflare))
            }
            return list
        }
    }

    func candidates(for code: MobilePairingCode) -> [MobileTransportCandidate] {
        candidates(
            service: code.service,
            tailnetHost: code.tailnetHost,
            tailnetPort: code.tailnetPort,
            funnelURL: code.funnelURL,
            cloudflareURL: code.cloudflareURL
        )
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
    /// When pairing or over WebSocket: the phone's one-time X25519 public key, which `proof` covers.
    var exchange: Data?
}

/// The Mac's reply. When pairing succeeds, it carries the Mac's half of the key exchange.
struct MobileWelcome: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String? = nil
    var mac: String? = nil
    /// When pairing or over WebSocket: the Mac's one-time X25519 public key.
    var exchange: Data? = nil
    /// Proof that the Mac holds the pairing or device key, covering both public keys.
    var proof: String? = nil
    /// Optional remote endpoints advertised by the Mac.
    var tailnetHost: String? = nil
    var tailnetPort: UInt16? = nil
    var funnelURL: String? = nil
    var cloudflareURL: String? = nil
}

/// What the QR code on the Mac carries.
struct MobilePairingCode: Equatable, Sendable {
    var service: String
    var pairingID: String
    var secret: Data
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?

    var url: URL {
        var components = URLComponents()
        components.scheme = "imcp"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: String(MobileLink.protocolVersion)),
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "id", value: pairingID),
            URLQueryItem(name: "secret", value: secret.base64URLEncodedString()),
        ]
        if let tailnetHost, !tailnetHost.isEmpty {
            items.append(URLQueryItem(name: "tailnet_host", value: tailnetHost))
        }
        if let tailnetPort, tailnetPort > 0 {
            items.append(URLQueryItem(name: "tailnet_port", value: String(tailnetPort)))
        }
        if let funnelURL, !funnelURL.isEmpty {
            items.append(URLQueryItem(name: "funnel_url", value: funnelURL))
        }
        if let cloudflareURL, !cloudflareURL.isEmpty {
            items.append(URLQueryItem(name: "cloudflare_url", value: cloudflareURL))
        }
        components.queryItems = items
        return components.url!
    }

    init(
        service: String,
        pairingID: String,
        secret: Data,
        tailnetHost: String? = nil,
        tailnetPort: UInt16? = nil,
        funnelURL: String? = nil,
        cloudflareURL: String? = nil
    ) {
        self.service = service
        self.pairingID = pairingID
        self.secret = secret
        self.tailnetHost = tailnetHost?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tailnetPort = (tailnetPort ?? 0) > 0 ? tailnetPort : nil
        self.funnelURL = MobileLink.normalizedWebSocketURL(funnelURL)
        self.cloudflareURL = MobileLink.normalizedWebSocketURL(cloudflareURL)
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
        let tailnetHost = items["tailnet_host"]
        let tailnetPort = items["tailnet_port"].flatMap(UInt16.init)
        let funnelURL = items["funnel_url"]
        let cloudflareURL = items["cloudflare_url"]
        self.init(
            service: service,
            pairingID: pairingID,
            secret: secret,
            tailnetHost: tailnetHost,
            tailnetPort: tailnetPort,
            funnelURL: funnelURL,
            cloudflareURL: cloudflareURL
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
