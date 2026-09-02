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

    /// A browser that times out without finding anything must be cancelled,
    /// not left running.
    func testTimedOutBrowserIsCancelled() async throws {
        let browser = NWBrowser(
            for: .bonjour(type: "_imcp-test-absent._tcp", domain: nil),
            using: .tcp
        )

        do {
            _ = try await BonjourDiscovery.discoverEndpoint(
                using: browser,
                timeout: .milliseconds(500),
                preferring: { _ in true }
            )
            XCTFail("Expected discovery to time out")
        } catch {
            // Expected.
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
