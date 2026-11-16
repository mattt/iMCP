import Darwin
import Foundation
import Network
import Security

/// Fetches a Client ID Metadata Document for the authorization server.
///
/// The URL comes from an unknown client on the internet, so the fetch can't reach this Mac or its networks:
/// it needs HTTPS to a public name, refuses redirects, and reads at most 16 KB.
/// The name is resolved once, every address must be public, and the connection goes to the first
/// address that was checked, so a name that changes its answer afterward gains nothing.
/// TLS still uses the name for SNI and for certificate verification.
/// The connection uses Network.framework directly, so no system proxy or URL loading cache is involved.
/// The request sends no cookies or credentials, and the response only ever feeds a JSON parser
/// whose result is shown to the owner.
enum ClientMetadataFetcher {
    struct Refused: Error {}

    static let maximumBytes = 16 * 1024
    static let maximumHeaderBytes = 8 * 1024

    /// Resolves a name to the raw bytes of its addresses: 4 for IPv4, 16 for IPv6.
    typealias Resolver = @Sendable (String) async throws -> [[UInt8]]
    /// Sends `request` to the address over TLS for `host`, and returns everything read until the connection closes.
    typealias Transport = @Sendable (_ host: String, _ address: [UInt8], _ request: Data) async throws -> Data

    static func fetch(_ url: URL) async throws -> Data {
        try await fetch(url, resolve: resolveAddresses, transport: connectAndRead)
    }

    static func fetch(_ url: URL, resolve: Resolver, transport: Transport) async throws -> Data {
        guard url.scheme == "https", url.port == nil || url.port == 443, let host = url.host(), isPublicName(host)
        else { throw Refused() }
        let addresses = try await resolve(host)
        guard let pinned = addresses.first, addresses.allSatisfy(isPublic(bytes:)) else { throw Refused() }

        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?" + query }
        // HTTP/1.0 keeps the server from chunking the body, and the connection closes after the response.
        let request = Data(
            "GET \(target) HTTP/1.0\r\nHost: \(host)\r\nAccept: application/json\r\nAccept-Encoding: identity\r\n\r\n"
                .utf8
        )
        return try body(ofResponse: try await transport(host, pinned, request))
    }

    /// The body of a `200` response. Anything else, including a redirect, is refused.
    static func body(ofResponse data: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator), end.lowerBound <= maximumHeaderBytes,
            let head = String(data: data[..<end.lowerBound], encoding: .utf8),
            let statusLine = head.split(separator: "\r\n", omittingEmptySubsequences: false).first
        else { throw Refused() }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1] == "200" else { throw Refused() }
        let body = data[end.upperBound...]
        guard body.count <= maximumBytes else { throw Refused() }
        return Data(body)
    }

    private static func resolveAddresses(_ host: String) async throws -> [[UInt8]] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                    continuation.resume(throwing: Refused())
                    return
                }
                defer { freeaddrinfo(first) }
                var found: [[UInt8]] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    guard let address = info.pointee.ai_addr, let bytes = rawBytes(address) else {
                        continuation.resume(throwing: Refused())
                        return
                    }
                    found.append(bytes)
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: found)
            }
        }
    }

    private static func rawBytes(_ address: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
        default:
            return nil
        }
    }

    private static func connectAndRead(host: String, address: [UInt8], request: Data) async throws -> Data {
        let endpointHost: NWEndpoint.Host
        switch address.count {
        case 4: endpointHost = IPv4Address(Data(address)).map { .ipv4($0) } ?? .name("", nil)
        case 16: endpointHost = IPv6Address(Data(address)).map { .ipv6($0) } ?? .name("", nil)
        default: throw Refused()
        }
        if case .name = endpointHost { throw Refused() }

        let tls = NWProtocolTLS.Options()
        // The server name sets SNI, and the certificate has to be valid for it.
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tls)
        let connection = NWConnection(host: endpointHost, port: 443, using: parameters)
        let queue = DispatchQueue(label: "imcp.metadata-fetch")
        let limit = maximumHeaderBytes + maximumBytes + 1

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    let state = FetchState(continuation)
                    connection.stateUpdateHandler = { newState in
                        switch newState {
                        case .ready:
                            connection.send(
                                content: request,
                                completion: .contentProcessed { error in
                                    if error != nil {
                                        state.finish(.failure(Refused()))
                                    } else {
                                        Self.receive(connection, state: state, limit: limit)
                                    }
                                }
                            )
                        case .failed, .cancelled, .waiting:
                            // A wait means the connection can't be made now, and a retry isn't wanted.
                            state.finish(.failure(Refused()))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw Refused()
            }
            defer {
                connection.cancel()
                group.cancelAll()
            }
            guard let data = try await group.next() else { throw Refused() }
            return data
        }
    }

    private static func receive(_ connection: NWConnection, state: FetchState, limit: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, isComplete, error in
            if let content { state.append(content) }
            if state.size > limit { return state.finish(.failure(Refused())) }
            if isComplete { return state.finish(.success(state.data)) }
            if error != nil { return state.finish(.failure(Refused())) }
            receive(connection, state: state, limit: limit)
        }
    }

    private final class FetchState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private(set) var data = Data()

        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        var size: Int { lock.withLock { data.count } }

        func append(_ more: Data) { lock.withLock { data.append(more) } }

        func finish(_ result: Result<Data, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }

    /// A DNS name with at least two labels, not an IP address and not a local or internal name.
    static func isPublicName(_ host: String) -> Bool {
        let name = host.lowercased()
        guard name.contains("."), !name.hasSuffix("."), name.utf8.count <= 253,
            name.utf8.allSatisfy({
                $0 == 0x2D || $0 == 0x2E || (0x30 ... 0x39).contains($0) || (0x61 ... 0x7A).contains($0)
            })
        else { return false }
        // An all-numeric last label would make this an IPv4 address in some forms.
        guard let last = name.split(separator: ".").last, !last.allSatisfy(\.isNumber) else { return false }
        let internalSuffixes = [
            ".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".ts.net", ".test", ".invalid",
        ]
        return !internalSuffixes.contains { name.hasSuffix($0) }
    }

    /// Whether a socket address is outside loopback, private, link-local, shared (such as Tailscale's),
    /// multicast, and unspecified ranges.
    static func isPublic(bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4: isPublicIPv4(bytes)
        case 16: isPublicIPv6(bytes)
        default: false
        }
    }

    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64 ... 127, _): return false
        case (169, 254, _): return false
        case (172, 16 ... 31, _): return false
        case (192, 168, _), (192, 0, 0), (192, 0, 2), (198, 18 ... 19, _), (198, 51, 100), (203, 0, 113): return false
        case (224 ... 255, _, _): return false
        default: return true
        }
    }

    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // IPv4-mapped addresses follow the IPv4 rules.
        if b[0 ..< 10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isPublicIPv4(Array(b[12...])) }
        if b[0] & 0xFE == 0xFC { return false }  // unique local fc00::/7
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return false }  // link-local fe80::/10
        if b[0] == 0xFF { return false }  // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }  // documentation
        if b[0 ..< 12].allSatisfy({ $0 == 0 }) { return false }  // ::/96: unspecified, loopback, IPv4-compatible
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B {
            // 64:ff9b::/96 and 64:ff9b:1::/48 translate to IPv4 addresses, and can reach private ones.
            if b[4 ..< 12].allSatisfy({ $0 == 0 }) { return false }
            if b[4] == 0x00, b[5] == 0x01 { return false }
        }
        if b[0] == 0x20, b[1] == 0x02 { return false }  // 6to4, 2002::/16
        if b[0] == 0xFE, b[1] & 0xC0 == 0xC0 { return false }  // deprecated site-local fec0::/10
        return true
    }
}
