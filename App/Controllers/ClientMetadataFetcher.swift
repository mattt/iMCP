import Darwin
import Foundation

/// Fetches a Client ID Metadata Document for the authorization server.
///
/// The URL comes from an unknown client on the internet, so the fetch can't reach this Mac or its networks:
/// it needs HTTPS to a public name, refuses redirects, and reads at most 16 KB.
/// The check resolves the name first, and the request resolves it again,
/// so a name that changes its answer between the two could still reach a private address.
/// The request sends no cookies or credentials, and the response only ever feeds a JSON parser
/// whose result is shown to the owner, so a hit on a private address returns nothing to the sender.
enum ClientMetadataFetcher {
    struct Refused: Error {}

    static let maximumBytes = 16 * 1024

    static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", let host = url.host(), isPublicName(host),
            try await resolvesOnlyToPublicAddresses(host)
        else { throw Refused() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Refused() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maximumBytes else { throw Refused() }
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
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

    private static func resolvesOnlyToPublicAddresses(_ host: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: false)
                    return
                }
                defer { freeaddrinfo(first) }
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                var any = false
                while let info = cursor {
                    any = true
                    guard let address = info.pointee.ai_addr, isPublic(address) else {
                        continuation.resume(returning: false)
                        return
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: any)
            }
        }
    }

    /// Whether a socket address is outside loopback, private, link-local, shared (such as Tailscale's),
    /// multicast, and unspecified ranges.
    static func isPublic(_ address: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            return isPublicIPv4(bytes)
        case AF_INET6:
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            return isPublicIPv6(bytes)
        default:
            return false
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
        if b.allSatisfy({ $0 == 0 }) || b == [UInt8](repeating: 0, count: 15) + [1] { return false }
        // IPv4-mapped addresses follow the IPv4 rules.
        if b[0 ..< 10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isPublicIPv4(Array(b[12...])) }
        if b[0] & 0xFE == 0xFC { return false }  // unique local fc00::/7
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return false }  // link-local fe80::/10
        if b[0] == 0xFF { return false }  // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }  // documentation
        return true
    }
}
