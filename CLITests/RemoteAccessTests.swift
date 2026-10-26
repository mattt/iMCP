import Foundation
import JSONSchema
import MCP
import XCTest

final class HTTPRequestParserTests: XCTestCase {
    private func parse(_ string: String) -> HTTPRequestParser.Result {
        HTTPRequestParser.parse(Data(string.utf8))
    }

    func testParsesRequestWithBody() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw =
            "POST /mcp?x=1 HTTP/1.1\r\nHost: mac.example.ts.net:4627\r\ncontent-type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let request, let length) = parse(raw) else {
            return XCTFail("Expected a request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.header("host"), "mac.example.ts.net:4627")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)
        XCTAssertTrue(request.keepAlive)
        XCTAssertEqual(length, raw.utf8.count)
    }

    func testWaitsForHeaderAndBody() {
        XCTAssertEqual(parse("POST /mcp HTTP/1.1\r\nHost: a"), .incomplete(expectsContinue: false))
        XCTAssertEqual(
            parse("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"),
            .incomplete(expectsContinue: false)
        )
        XCTAssertEqual(
            parse("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n"),
            .incomplete(expectsContinue: true)
        )
    }

    func testLeavesNextRequestInBuffer() {
        let first = "GET /mcp HTTP/1.1\r\nHost: a\r\n\r\n"
        let second = "DELETE /mcp HTTP/1.1\r\nHost: a\r\n\r\n"
        guard case .request(let request, let length) = parse(first + second) else {
            return XCTFail("Expected a request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(length, first.utf8.count)
    }

    func testJoinsRepeatedHeaders() {
        guard case .request(let request, _) = parse("GET / HTTP/1.1\r\nAccept: a\r\naccept: b\r\n\r\n") else {
            return XCTFail("Expected a request")
        }
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.header("Accept"), "a, b")
    }

    func testConnectionHeaderControlsKeepAlive() {
        guard case .request(let closing, _) = parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n"),
            case .request(let old, _) = parse("GET / HTTP/1.0\r\n\r\n"),
            case .request(let oldKeepAlive, _) = parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        else {
            return XCTFail("Expected requests")
        }
        XCTAssertFalse(closing.keepAlive)
        XCTAssertFalse(old.keepAlive)
        XCTAssertTrue(oldKeepAlive.keepAlive)
    }

    func testRejectsMalformedRequests() {
        XCTAssertEqual(statusOf(parse("POST\r\n\r\n")), 400)
        XCTAssertEqual(statusOf(parse("GET mcp HTTP/1.1\r\n\r\n")), 400)
        XCTAssertEqual(statusOf(parse("GET / HTTP/2\r\n\r\n")), 505)
        XCTAssertEqual(statusOf(parse("GET / HTTP/1.1\r\nNo colon\r\n\r\n")), 400)
        XCTAssertEqual(statusOf(parse("GET / HTTP/1.1\r\nBad Name: x\r\n\r\n")), 400)
        XCTAssertEqual(statusOf(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")), 400)
        XCTAssertEqual(statusOf(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")), 411)
        XCTAssertEqual(
            statusOf(parse("POST / HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maximumBodyLength + 1)\r\n\r\n")),
            413
        )
        XCTAssertEqual(statusOf(parse("GET / HTTP/1.1\r\n" + String(repeating: "a", count: 17 * 1024))), 431)
    }

    private func statusOf(_ result: HTTPRequestParser.Result) -> Int? {
        if case .failure(let status, _) = result { status } else { nil }
    }
}

final class HTTPResponseEncoderTests: XCTestCase {
    func testHeadWithContentLength() {
        let head = HTTPResponseEncoder.head(
            status: 202,
            headers: ["MCP-Session-Id": "abc", "Connection": "keep-alive", "Content-Length": "99"],
            contentLength: 0,
            keepAlive: true
        )
        XCTAssertEqual(
            String(decoding: head, as: UTF8.self),
            "HTTP/1.1 202 Accepted\r\nMCP-Session-Id: abc\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
        )
    }

    func testChunkedHeadDropsUnsafeHeaders() {
        let head = HTTPResponseEncoder.head(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "X-Bad": "a\r\nInjected: b"],
            contentLength: nil,
            keepAlive: false
        )
        XCTAssertEqual(
            String(decoding: head, as: UTF8.self),
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )
    }

    func testChunks() {
        XCTAssertEqual(String(decoding: HTTPResponseEncoder.chunk(Data(count: 26)).prefix(4), as: UTF8.self), "1a\r\n")
        XCTAssertEqual(HTTPResponseEncoder.chunk(Data(count: 26)).count, 4 + 26 + 2)
        // An empty chunk would end the body.
        XCTAssertTrue(HTTPResponseEncoder.chunk(Data()).isEmpty)
    }
}

final class AccessTokenTests: XCTestCase {
    private func tool(_ name: String, readOnly: Bool?) -> Tool {
        Tool(
            name: name,
            description: "",
            inputSchema: .object(properties: [:]),
            annotations: .init(readOnlyHint: readOnly)
        ) { _ in "" }
    }

    func testPermissions() {
        let read = tool("read", readOnly: true)
        let write = tool("write", readOnly: false)
        let unknown = tool("unknown", readOnly: nil)

        XCTAssertTrue(ToolPermissions.readOnly.allows(read))
        XCTAssertFalse(ToolPermissions.readOnly.allows(write))
        XCTAssertFalse(ToolPermissions.readOnly.allows(unknown))
        XCTAssertTrue(ToolPermissions.allTools.allows(write))
        XCTAssertTrue(ToolPermissions.allTools.allows(unknown))
        XCTAssertEqual(ToolPermissions.custom(["write"]).allowedNames(in: [read, write, unknown]), ["write"])
        XCTAssertEqual(ToolPermissions.readOnly.allowedNames(in: [read, write, unknown]), ["read"])
    }

    func testSecretsAreDistinctAndHashed() {
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        XCTAssertTrue(secret.hasPrefix("imcp_"))
        XCTAssertEqual(secret.count, 5 + 43)
        XCTAssertFalse(secret.contains("+") || secret.contains("/") || secret.contains("="))
        XCTAssertEqual(token.secretHash, AccessToken.hash(secret))
        XCTAssertNotEqual(AccessToken.makeSecret(), AccessToken.makeSecret())
    }

    func testStoreFindsTokensBySecretAndPersists() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AccessTokenStore(defaults: defaults)
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        store.add(token)
        XCTAssertEqual(store.token(secret: secret)?.id, token.id)
        XCTAssertNil(store.token(secret: "imcp_wrong"))
        XCTAssertNil(store.token(secret: "wrong"))

        // A new store reads the same tokens.
        XCTAssertEqual(AccessTokenStore(defaults: defaults).all, [token])

        store.modify(id: token.id) { $0.permissions = .custom(["write"]) }
        XCTAssertEqual(AccessTokenStore(defaults: defaults).token(id: token.id)?.permissions, .custom(["write"]))

        store.remove(id: token.id)
        XCTAssertNil(store.token(secret: secret))
        XCTAssertTrue(AccessTokenStore(defaults: defaults).all.isEmpty)
    }

    func testRerollReplacesSecretAndKeepsSettings() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AccessTokenStore(defaults: defaults)
        var (token, oldSecret) = AccessToken.make(name: "Laptop", permissions: .allTools)
        token.lastUsedAt = Date()
        token.lastUsedDevice = "MacBook Pro"
        store.add(token)

        let newSecret = try XCTUnwrap(store.modify(id: token.id) { $0.reroll() })
        XCTAssertNotEqual(newSecret, oldSecret)
        XCTAssertNil(store.token(secret: oldSecret))
        let rerolled = try XCTUnwrap(store.token(secret: newSecret))
        XCTAssertEqual(rerolled.id, token.id)
        XCTAssertEqual(rerolled.name, "Laptop")
        XCTAssertEqual(rerolled.permissions, .allTools)
        XCTAssertNotNil(rerolled.rolledAt)
        XCTAssertNil(rerolled.lastUsedAt)
        XCTAssertNil(rerolled.lastUsedDevice)
    }
}
