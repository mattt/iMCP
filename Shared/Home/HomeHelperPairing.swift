import CommonCrypto
import CryptoKit
import Foundation
import MCP
import Network
import Security

/// Pairs iMCP with iMCP Helper through a one-time code that the helper shows in its window.
///
/// Until it is paired, the helper accepts only pairing connections,
/// which use TLS with a pre-shared key derived from the code.
/// On a pairing connection, iMCP sends a new random 256-bit key,
/// and both apps keep that key in their keychains.
/// Later connections use TLS with that key,
/// so a connection without it fails the TLS handshake.
///
/// A process that pretends to be the helper while iMCP pairs
/// receives a TLS `Finished` message that it can use to search for the code offline.
/// The key derivation makes each guess slow,
/// and the code stops working once iMCP pairs or after a few failed handshakes.
enum HomeHelperPairing {
    /// The version of the protocol between iMCP and the helper.
    /// The helper declares it in its Info.plist and its Bonjour TXT record;
    /// helpers from before pairing declare neither.
    static let protocolVersion = 3
    static let protocolVersionInfoKey = "iMCPHelperProtocolVersion"
    static let protocolVersionTXTKey = "protocol"
    static let processIDTXTKey = "pid"
    /// Present with the value `1` while the helper shows a code.
    static let pairingTXTKey = "pairing"
    static let serviceType = "_imcp-helper._tcp"

    /// How many failed pairing handshakes the helper allows before it replaces the code.
    static let failedPairingLimit = 5
    /// PBKDF2-HMAC-SHA256 iterations, about half a second on Apple silicon.
    static let keyDerivationIterations: UInt32 = 3_500_000
    /// The only cipher suite that the apps accept: ECDHE with the pre-shared key,
    /// so a recorded connection stays secret even if the code or key is found later.
    static let cipherSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!

    /// Crockford's base32 alphabet, which leaves out I, L, O, and U.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let codeLength = 8
    private static let groupLength = 4
    private static let keyDerivationSalt = Data("iMCP Helper pairing code v3".utf8)
    private static let pairingIdentity = Data("iMCP Helper pairing v3".utf8)
    private static let pairedIdentity = Data("iMCP Helper paired v3".utf8)

    // MARK: - Code

    /// Makes a code of eight characters, which holds 40 random bits.
    static func generateCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HomeError("Cannot create a pairing code for iMCP Helper.")
        }
        // 256 is a multiple of 32, so every character is equally likely.
        return format(String(bytes.map { alphabet[Int($0 & 31)] }))
    }

    /// Returns the code's characters without separators, in uppercase,
    /// or nil if the text isn't a code.
    /// Accepts spaces and hyphens, either case,
    /// and the letters that Crockford's base32 reads as digits (I and L as 1, O as 0).
    static func normalize(_ text: String) -> String? {
        var characters: [Character] = []
        for character in text.uppercased() {
            switch character {
            case " ", "-": continue
            case "I", "L": characters.append("1")
            case "O": characters.append("0")
            case _ where alphabet.contains(character): characters.append(character)
            default: return nil
            }
        }
        guard characters.count == codeLength else { return nil }
        return String(characters)
    }

    /// Formats a code in two hyphen-separated groups, such as `0123-ABCD`.
    static func format(_ code: String) -> String {
        let characters = Array(normalize(code) ?? code)
        return stride(from: 0, to: characters.count, by: groupLength)
            .map { String(characters[$0 ..< min($0 + groupLength, characters.count)]) }
            .joined(separator: "-")
    }

    // MARK: - Keys

    /// Derives the pairing connection's pre-shared key from a code with PBKDF2-HMAC-SHA256.
    static func pairingKey(code: String) throws -> SymmetricKey {
        guard let code = normalize(code) else { throw HomeError("That isn't an iMCP Helper pairing code.") }
        let password = Array(code.utf8).map { CChar(bitPattern: $0) }
        var key = [UInt8](repeating: 0, count: 32)
        let status = keyDerivationSalt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password,
                password.count,
                salt.bindMemory(to: UInt8.self).baseAddress,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                keyDerivationIterations,
                &key,
                key.count
            )
        }
        guard status == kCCSuccess else { throw HomeError("Cannot derive the iMCP Helper pairing key (\(status)).") }
        return SymmetricKey(data: key)
    }

    /// Makes the random 256-bit key that iMCP sends when it pairs.
    static func generateKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// TCP parameters for a pairing connection, with the code's key.
    static func pairingParameters(code: String) throws -> NWParameters {
        parameters(key: try pairingKey(code: code), identity: pairingIdentity)
    }

    /// TCP parameters for a paired connection, with the key that iMCP sent when it paired.
    static func parameters(key: SymmetricKey) -> NWParameters {
        parameters(key: key, identity: pairedIdentity)
    }

    /// Returns TCP parameters for the loopback interface
    /// with TLS 1.2 that uses only one pre-shared key.
    private static func parameters(key: SymmetricKey, identity: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            options,
            key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            identity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )
        // PSK cipher suites exist only in TLS 1.2.
        // Network.framework still offers and accepts its default PSK suites,
        // so both apps also check the negotiated suite with `usesCipherSuite(_:)`.
        sec_protocol_options_append_tls_ciphersuite(options, cipherSuite)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return parameters
    }

    /// Whether a ready connection negotiated `cipherSuite`.
    static func usesCipherSuite(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return false }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata) == cipherSuite
    }

    /// The one request that a pairing connection accepts:
    /// iMCP sends the key that both apps use from then on.
    enum Pair: MCP.Method {
        static let name = "imcp/pair"

        struct Parameters: Hashable, Codable, Sendable {
            let key: Data
        }
    }

    // MARK: - Keychain

    /// Keeps the pairing key as a generic password in this app's keychain.
    struct Keychain: Sendable {
        /// The helper's key.
        static let helper = Keychain(service: "iMCP Helper pairing key")
        /// iMCP's key.
        /// Its own service keeps the apps' items apart in the login keychain,
        /// which unsigned builds use.
        static let app = Keychain(service: "iMCP pairing key for iMCP Helper")

        let service: String
        private let account = "pairing-key"

        /// Returns the stored key, or nil if there is none.
        func read() throws -> SymmetricKey? {
            for dataProtection in [true, false] {
                var query = baseQuery(dataProtection: dataProtection)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data, data.count == 32 else { return nil }
                    return SymmetricKey(data: data)
                case errSecItemNotFound:
                    return nil
                case errSecMissingEntitlement:
                    continue
                default:
                    throw HomeError("Cannot read the iMCP Helper pairing key from the keychain (\(status)).")
                }
            }
            return nil
        }

        func save(_ key: SymmetricKey) throws {
            for dataProtection in [true, false] {
                let query = baseQuery(dataProtection: dataProtection)
                SecItemDelete(query as CFDictionary)
                var item = query
                item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
                // The data protection keychain applies this attribute; the file-based keychain ignores it.
                if dataProtection {
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                }
                let status = SecItemAdd(item as CFDictionary, nil)
                if status == errSecSuccess { return }
                // Apps without an application identifier, such as unsigned Debug builds,
                // can't use the data protection keychain.
                if status != errSecMissingEntitlement {
                    throw HomeError("Cannot save the iMCP Helper pairing key in the keychain (\(status)).")
                }
            }
        }

        func delete() throws {
            for dataProtection in [true, false] {
                let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
                guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                    throw HomeError("Cannot delete the iMCP Helper pairing key from the keychain (\(status)).")
                }
            }
        }

        private func baseQuery(dataProtection: Bool) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: dataProtection,
            ]
        }
    }
}
