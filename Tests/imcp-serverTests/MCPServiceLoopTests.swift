import XCTest

final class MCPServiceLoopTests: XCTestCase {

    /// Stdin EOF used to complete `proxy.start()` without throwing, and the
    /// service loop treated that as a reason to connect to the app again.
    /// With stdin already closed, that reconnects until crash.
    func testSuccessfulProxyReturnTerminates() {
        XCTAssertEqual(MCPServiceLoop.decision(error: nil), .terminate)
    }

    func testStdinOrNetworkCloseTerminates() {
        XCTAssertEqual(
            MCPServiceLoop.decision(error: StdioProxyError.connectionClosed),
            .terminate
        )
    }

    func testCancellationTerminates() {
        XCTAssertEqual(
            MCPServiceLoop.decision(error: CancellationError()),
            .terminate
        )
    }

    func testUnexpectedErrorReconnectsAfterBackoff() {
        struct Unexpected: Error {}
        XCTAssertEqual(
            MCPServiceLoop.decision(error: Unexpected()),
            .reconnect(seconds: 5)
        )
    }
}
