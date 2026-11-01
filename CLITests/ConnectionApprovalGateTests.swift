import Foundation
import MCP
import XCTest

/// Tests that no request reaches a tool handler
/// before the user approves the connection.
///
/// Each test sends raw JSON-RPC messages over an in-memory transport,
/// so that it can send requests in an order that a compliant client would not.
final class ConnectionApprovalGateTests: XCTestCase {
    func testRequestsBeforeInitializeAreRejected() async throws {
        let connection = try await Connection()

        try await connection.client.send(id: "list", method: ListTools.name)
        try await connection.client.send(id: "call", method: CallTool.name, params: ["name": "probe"])

        try await connection.assertRejected(id: "list")
        try await connection.assertRejected(id: "call")
        let decisionRequests = await connection.decision.requests
        XCTAssertEqual(decisionRequests, 0)

        await connection.server.stop()
    }

    func testRequestsWhileApprovalIsPendingAreRejected() async throws {
        let connection = try await Connection()

        try await connection.client.send(id: "initialize", method: Initialize.name, params: initializeParameters)
        await connection.decision.waitForRequests(1)

        try await connection.client.send(id: "list", method: ListTools.name)
        try await connection.client.send(id: "call", method: CallTool.name, params: ["name": "probe"])
        try await connection.assertRejected(id: "list")
        try await connection.assertRejected(id: "call")

        await connection.decision.resolve(true)
        try await connection.client.assertResult(id: "initialize")

        try await connection.client.send(id: "list-approved", method: ListTools.name)
        try await connection.client.send(
            id: "call-approved",
            method: CallTool.name,
            params: ["name": "probe"]
        )
        try await connection.client.assertResult(id: "list-approved")
        try await connection.client.assertResult(id: "call-approved")
        let registrations = await connection.registrations.value
        let calls = await connection.calls.value
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(calls, 1)

        await connection.server.stop()
    }

    func testDeniedConnectionGetsNoHandlers() async throws {
        let connection = try await Connection()
        await connection.decision.resolve(false)

        try await connection.client.send(id: "initialize", method: Initialize.name, params: initializeParameters)
        try await connection.client.assertError(id: "initialize")

        try await connection.client.send(id: "list", method: ListTools.name)
        try await connection.client.send(id: "call", method: CallTool.name, params: ["name": "probe"])
        try await connection.assertRejected(id: "list")
        try await connection.assertRejected(id: "call")

        await connection.server.stop()
    }

    func testSecondInitializeGetsNoHandlers() async throws {
        let connection = try await Connection()

        try await connection.client.send(id: "first", method: Initialize.name, params: initializeParameters)
        await connection.decision.waitForRequests(1)

        try await connection.client.send(id: "second", method: Initialize.name, params: initializeParameters)
        try await connection.client.assertError(id: "second")

        await connection.decision.resolve(true)
        try await connection.client.assertResult(id: "first")

        try await connection.client.send(id: "third", method: Initialize.name, params: initializeParameters)
        try await connection.client.assertError(id: "third")

        let decisionRequests = await connection.decision.requests
        let registrations = await connection.registrations.value
        XCTAssertEqual(decisionRequests, 1)
        XCTAssertEqual(registrations, 1)

        await connection.server.stop()
    }

    /// A handler refuses requests until approval
    /// even if it is registered before the connection is approved.
    func testApprovedHandlerRefusesUnapprovedConnection() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let gate = ConnectionApprovalGate()
        let calls = Counter()
        let server = MCP.Server(name: "test", version: "1.0")
        await server.withApprovedMethodHandler(CallTool.self, gate: gate) { _ in
            await calls.increment()
            return CallTool.Result(content: [])
        }
        try await server.start(transport: serverTransport)
        let client = try await RawClient(transport: clientTransport)

        try await client.send(id: "call", method: CallTool.name, params: ["name": "probe"])
        try await client.assertError(id: "call", code: MCPError.invalidRequest(nil).code)
        let callsBeforeApproval = await calls.value
        XCTAssertEqual(callsBeforeApproval, 0)

        try await gate.approve { true }
        try await client.send(id: "call-approved", method: CallTool.name, params: ["name": "probe"])
        try await client.assertResult(id: "call-approved")

        let count = await calls.value
        XCTAssertEqual(count, 1)

        await server.stop()
    }
}

private let initializeParameters: [String: Any] = [
    "protocolVersion": "2025-06-18",
    "capabilities": [String: Any](),
    "clientInfo": ["name": "test", "version": "1.0"],
]

/// A server started with an approval gate, and a client connected to it.
private struct Connection {
    let server: MCP.Server
    let client: RawClient
    let decision = Decision()
    let registrations = Counter()
    let calls = Counter()

    init() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = MCP.Server(
            name: "test",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true))
        )
        let gate = ConnectionApprovalGate()
        let decision = decision
        let registrations = registrations
        let calls = calls

        try await server.start(
            transport: serverTransport,
            gate: gate,
            approve: { _ in await decision.wait() },
            registerHandlers: {
                await server.withApprovedMethodHandler(ListTools.self, gate: gate) { _ in
                    ListTools.Result(tools: [])
                }
                await server.withApprovedMethodHandler(CallTool.self, gate: gate) { _ in
                    await calls.increment()
                    return CallTool.Result(content: [])
                }
                await registrations.increment()
            }
        )

        self.server = server
        self.client = try await RawClient(transport: clientTransport)
    }

    /// Asserts that a request sent before approval got a "method not found" error
    /// because no handler was registered,
    /// and that no tool ran.
    func assertRejected(id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await client.assertError(id: id, code: MCPError.methodNotFound(nil).code, file: file, line: line)
        let registrations = await registrations.value
        let calls = await calls.value
        XCTAssertEqual(registrations, 0, "Expected no handlers after \(id)", file: file, line: line)
        XCTAssertEqual(calls, 0, "Expected no tool calls after \(id)", file: file, line: line)
    }
}

/// The user's decision on a connection, which a test makes when it is ready.
private actor Decision {
    private(set) var requests = 0
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async -> Bool {
        requests += 1
        let ready = requestWaiters.filter { requests >= $0.count }
        requestWaiters.removeAll { requests >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }

        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: Bool) {
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// Returns once the server has asked for a decision `count` times.
    func waitForRequests(_ count: Int) async {
        guard requests < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// Sends JSON-RPC requests and collects the responses by ID.
private final class RawClient {
    private struct StreamEnded: Error {}

    private let transport: InMemoryTransport
    private var messages: AsyncThrowingStream<Data, Error>.AsyncIterator
    private var responses: [String: [String: Any]] = [:]

    init(transport: InMemoryTransport) async throws {
        self.transport = transport
        try await transport.connect()
        self.messages = await transport.receive().makeAsyncIterator()
    }

    func send(id: String, method: String, params: [String: Any] = [:]) async throws {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try await transport.send(JSONSerialization.data(withJSONObject: request))
    }

    func assertError(
        id: String,
        code: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try await response(to: id)
        XCTAssertNil(response["result"], "Expected no result for \(id): \(response)", file: file, line: line)
        guard let error = response["error"] as? [String: Any] else {
            return XCTFail("Expected an error for \(id): \(response)", file: file, line: line)
        }
        if let code {
            XCTAssertEqual(error["code"] as? Int, code, "Unexpected error for \(id): \(error)", file: file, line: line)
        }
    }

    func assertResult(id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let response = try await response(to: id)
        XCTAssertNotNil(response["result"], "Expected a result for \(id): \(response)", file: file, line: line)
        XCTAssertNil(response["error"], "Expected no error for \(id): \(response)", file: file, line: line)
    }

    private func response(to id: String) async throws -> [String: Any] {
        while responses[id] == nil {
            guard let data = try await messages.next() else { throw StreamEnded() }
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let message, let responseID = message["id"] as? String {
                responses[responseID] = message
            }
        }
        return responses.removeValue(forKey: id)!
    }
}
