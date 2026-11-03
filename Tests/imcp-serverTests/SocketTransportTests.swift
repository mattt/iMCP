import Darwin
import Foundation
import MCP
import XCTest

final class SocketTransportTests: XCTestCase {
    func testReceivesMessagesSplitAcrossWrites() async throws {
        let (local, remote) = try socketPair()
        defer { close(remote) }
        let transport = SocketTransport(descriptor: local)
        try await transport.connect()

        try write("{\"a\":1}\n{\"b\"", to: remote)
        try write(":2}\n\n", to: remote)
        close(remote)

        var messages: [String] = []
        for try await message in await transport.receive() {
            messages.append(String(decoding: message, as: UTF8.self))
        }
        XCTAssertEqual(messages, [#"{"a":1}"#, #"{"b":2}"#])
        await transport.disconnect()
    }

    func testSendAppendsNewline() async throws {
        let (local, remote) = try socketPair()
        defer { close(remote) }
        let transport = SocketTransport(descriptor: local)
        try await transport.connect()

        try await transport.send(Data(#"{"c":3}"#.utf8))

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(remote, &buffer, buffer.count)
        XCTAssertEqual(String(decoding: buffer[..<max(count, 0)], as: UTF8.self), "{\"c\":3}\n")
        await transport.disconnect()
    }

    func testDisconnectClosesSocketThatNeverConnected() async throws {
        let (local, remote) = try socketPair()
        defer { close(remote) }
        let transport = SocketTransport(descriptor: local)

        await transport.disconnect()

        // The peer sees end of file once the channel closes the descriptor.
        var byte: UInt8 = 0
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(remote, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        XCTAssertEqual(read(remote, &byte, 1), 0)
    }

    func testMCPSessionOverSocket() async throws {
        let (serverEnd, clientEnd) = try socketPair()
        let server = MCP.Server(
            name: "Test",
            version: "1.0",
            capabilities: .init(tools: .init(listChanged: true))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [.init(name: "ping", description: "Ping", inputSchema: .object([:]))])
        }
        let initialized = expectation(description: "initialize hook")
        try await server.start(transport: SocketTransport(descriptor: serverEnd)) { clientInfo, _ in
            XCTAssertEqual(clientInfo.name, "Test Client")
            initialized.fulfill()
        }

        let client = MCP.Client(name: "Test Client", version: "1.0")
        let result = try await client.connect(transport: SocketTransport(descriptor: clientEnd))
        XCTAssertEqual(result.serverInfo.name, "Test")
        await fulfillment(of: [initialized], timeout: 5)

        let (tools, _) = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["ping"])

        await client.disconnect()
        await server.stop()
    }

    func testFramerRejectsLongMessages() {
        let framer = LineFramer(maximumLength: 4)
        XCTAssertEqual(try framer.append(Data("abcd\n".utf8)), [Data("abcd".utf8)])
        XCTAssertThrowsError(try framer.append(Data("abcde".utf8)))
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func write(_ string: String, to descriptor: Int32) throws {
        let bytes = Array(string.utf8)
        guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
