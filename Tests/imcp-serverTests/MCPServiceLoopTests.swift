import XCTest

final class MCPServiceLoopTests: XCTestCase {

    /// Stdin EOF used to complete `proxy.start()` without throwing, and the
    /// service loop treated that as a reason to connect to the app again.
    /// With stdin already closed, that reconnects until crash.
    func testSuccessfulProxyReturnTerminates() {
        XCTAssertEqual(MCPServiceLoop.decision(error: nil, hasReadClientInput: false), .terminate)
    }

    func testStdinOrNetworkCloseTerminates() {
        XCTAssertEqual(
            MCPServiceLoop.decision(error: StdioProxyError.connectionClosed, hasReadClientInput: false),
            .terminate
        )
    }

    func testCancellationTerminates() {
        XCTAssertEqual(
            MCPServiceLoop.decision(error: CancellationError(), hasReadClientInput: false),
            .terminate
        )
    }

    func testUnexpectedErrorBeforeClientInputReconnectsAfterBackoff() {
        struct Unexpected: Error {}
        XCTAssertEqual(
            MCPServiceLoop.decision(error: Unexpected(), hasReadClientInput: false),
            .reconnect(seconds: 5)
        )
    }

    /// The app approved the connection that carried the client's initialize request.
    /// A new connection has no approval,
    /// so continuing the session on it would fail the client's later requests.
    func testUnexpectedErrorAfterClientInputTerminates() {
        struct Unexpected: Error {}
        XCTAssertEqual(
            MCPServiceLoop.decision(error: Unexpected(), hasReadClientInput: true),
            .terminate
        )
    }
}
