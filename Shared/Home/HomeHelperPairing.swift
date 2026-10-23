import CryptoKit
import Foundation
import Network
import Security

/// Pairs iMCP with iMCP Helper through a code that the helper shows in its window.
///
/// The helper makes the code once and keeps it in its keychain.
/// The user enters it in iMCP, which keeps it in its own keychain.
/// Both apps derive a TLS pre-shared key from the code,
/// so a connection without the code fails the TLS handshake,
/// and a process that pretends to be the helper learns nothing that it can use.
enum HomeHelperPairing {
    /// The version of the protocol between iMCP and the helper.
    /// The helper declares it in its Info.plist and its Bonjour TXT record;
    /// helpers from before pairing declare neither.
    static let protocolVersion = 2
    static let protocolVersionInfoKey = "iMCPHelperProtocolVersion"
    static let protocolVersionTXTKey = "protocol"
    static let processIDTXTKey = "pid"
    static let serviceType = "_imcp-helper._tcp"

    /// Crockford's base32 alphabet, which leaves out I, L, O, and U.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let groupCount = 4
    private static let groupLength = 5
    private static let keyLabel = Data("iMCP Helper TLS-PSK v2".utf8)
    private static let keyIdentity = Data("iMCP Helper".utf8)

    /// Makes a code of four groups of five characters, which holds 100 random bits.
    static func generateCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: groupCount * groupLength)
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
        guard characters.count == groupCount * groupLength else { return nil }
        return String(characters)
    }

    /// Formats a code in hyphen-separated groups, such as `0123A-BCDEF-GHJKM-NPQRS`.
    static func format(_ code: String) -> String {
        let characters = Array(normalize(code) ?? code)
        return stride(from: 0, to: characters.count, by: groupLength)
            .map { String(characters[$0 ..< min($0 + groupLength, characters.count)]) }
            .joined(separator: "-")
    }

    /// Derives the TLS pre-shared key from a code with HKDF-SHA256.
    static func key(for code: String) throws -> SymmetricKey {
        guard let code = normalize(code) else { throw HomeError("That isn't an iMCP Helper pairing code.") }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            info: keyLabel,
            outputByteCount: 32
        )
    }

    /// Returns TCP parameters for the loopback interface
    /// with TLS 1.2 that uses only the code's pre-shared key.
    static func parameters(code: String) throws -> NWParameters {
        let key = try key(for: code)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            options,
            key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            keyIdentity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )
        // PSK cipher suites exist only in TLS 1.2.
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return parameters
    }

    // MARK: - Keychain

    /// Keeps a code as a generic password in this app's keychain.
    struct Keychain: Sendable {
        /// The helper's own code.
        static let helper = Keychain(service: "iMCP Helper pairing code")
        /// The code that the user entered in iMCP.
        /// Its own service keeps the apps' items apart in the login keychain,
        /// which unsigned builds use.
        static let app = Keychain(service: "iMCP pairing code for iMCP Helper")

        let service: String
        private let account = "pairing-code"

        /// Returns the stored code, or nil if there is none.
        func read() throws -> String? {
            for dataProtection in [true, false] {
                var query = baseQuery(dataProtection: dataProtection)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
                case errSecItemNotFound:
                    return nil
                case errSecMissingEntitlement:
                    continue
                default:
                    throw HomeError("Cannot read the iMCP Helper pairing code from the keychain (\(status)).")
                }
            }
            return nil
        }

        func save(_ code: String) throws {
            for dataProtection in [true, false] {
                let query = baseQuery(dataProtection: dataProtection)
                SecItemDelete(query as CFDictionary)
                var item = query
                item[kSecValueData as String] = Data(code.utf8)
                // The data protection keychain applies this attribute; the file-based keychain ignores it.
                if dataProtection {
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                }
                let status = SecItemAdd(item as CFDictionary, nil)
                if status == errSecSuccess { return }
                // Apps without an application identifier, such as unsigned Debug builds,
                // can't use the data protection keychain.
                if status != errSecMissingEntitlement {
                    throw HomeError("Cannot save the iMCP Helper pairing code in the keychain (\(status)).")
                }
            }
        }

        func delete() {
            for dataProtection in [true, false] {
                SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
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
