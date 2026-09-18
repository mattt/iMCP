import Network
import XCTest

/// Regression tests for `BonjourDiscovery`.
///
/// `imcp-server` retries discovery in a loop.
/// Every browser it starts must be cancelled before the next attempt,
/// or each one keeps a `DNSServiceBrowse` connection to `mDNSResponder` open.
/// Leaking one per attempt eventually exhausts the daemon's descriptors
/// and breaks DNS for every process on the machine (#192).
final class BonjourDiscoveryTests: XCTestCase {
    private let serviceEndpoint = NWEndpoint.service(
        name: "iMCP",
        type: "_mcp._tcp",
        domain: "local.",
        interface: nil
    )

    func testAdvertisedPortUsesIPv4Loopback() {
        for number: UInt16 in [1, 54321, 65535] {
            let endpoint = BonjourDiscovery.connectionEndpoint(
                for: serviceEndpoint,
                metadata: .bonjour(NWTXTRecord(["port": String(number)]))
            )

            XCTAssertEqual(endpoint, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: number)!))
        }
    }

    func testMissingPortUsesServiceEndpoint() {
        for metadata: NWBrowser.Result.Metadata in [.none, .bonjour(NWTXTRecord(["version": "1"]))] {
            XCTAssertEqual(
                BonjourDiscovery.connectionEndpoint(for: serviceEndpoint, metadata: metadata),
                serviceEndpoint
            )
        }
    }

    func testInvalidPortUsesServiceEndpoint() {
        for value in ["", "0", "-1", "65536", "abc", "http", "12.5"] {
            XCTAssertEqual(
                BonjourDiscovery.connectionEndpoint(
                    for: serviceEndpoint,
                    metadata: .bonjour(NWTXTRecord(["port": value]))
                ),
                serviceEndpoint,
                "Expected fallback for port value: \(value)"
            )
        }
    }

    /// A browser that times out without finding anything must be cancelled,
    /// not left running.
    func testTimedOutBrowserIsCancelled() async throws {
        // Bonjour service names are limited to 15 characters,
        // so keep this one valid; an invalid type fails the browser immediately
        // instead of exercising the timeout path.
        let browser = NWBrowser(
            for: .bonjour(type: "_imcp-absent._tcp", domain: nil),
            using: .tcp
        )

        do {
            _ = try await BonjourDiscovery.discoverEndpoint(
                using: browser,
                timeout: .milliseconds(500),
                preferring: { _ in true }
            )
            XCTFail("Expected discovery to time out")
        } catch BonjourDiscovery.Error.timeout {
            // Expected: nothing advertises this type, so only the timeout can end discovery.
        } catch {
            XCTFail("Expected the timeout error, got \(error)")
        }

        let cancelled = await waitForCancellation(of: browser)
        XCTAssertTrue(cancelled, "Browser was left running after timeout")
    }

    /// Cancellation is reported asynchronously, so poll briefly for it.
    private func waitForCancellation(of browser: NWBrowser, attempts: Int = 40) async -> Bool {
        for _ in 0 ..< attempts {
            if case .cancelled = browser.state { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
