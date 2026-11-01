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
        token.boundDevice = .init(stableID: "node-a", name: "MacBook Pro")
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
        XCTAssertNil(rerolled.boundDevice)
        try store.bind(rerolled, to: .init(stableID: "node-b", name: "Other Mac"))
        XCTAssertEqual(store.token(id: token.id)?.boundDevice?.stableID, "node-b")
    }

    func testOldStoredTokenDecodesWithoutBinding() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(
            #"[{"id":"BFA1562C-E2D4-4914-9BD3-0487301CC00B","name":"Old token","permissions":{"readOnly":{}},"secretHash":"AQID","createdAt":0,"lastUsedAt":1,"lastUsedDevice":"Old Mac"}]"#
                .utf8
        )
        defaults.set(data, forKey: "remoteAccessTokens")
        let token = try XCTUnwrap(AccessTokenStore(defaults: defaults).all.first)
        XCTAssertEqual(token.name, "Old token")
        XCTAssertNil(token.boundDevice)
        XCTAssertEqual(token.lastUsedDevice, "Old Mac")
    }

    func testConcurrentBindingPersistsOnlyOneNode() async throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(defaults: defaults)
        let (token, _) = AccessToken.make(name: "Race", permissions: .readOnly)
        store.add(token)

        let winners = await withTaskGroup(of: String?.self) { group in
            for index in 0 ..< 32 {
                group.addTask {
                    let node = "node-\(index)"
                    do {
                        try store.bind(token, to: .init(stableID: node, name: "Mac"))
                        return node
                    } catch {
                        return nil
                    }
                }
            }
            var winners: [String] = []
            for await winner in group {
                if let winner { winners.append(winner) }
            }
            return winners
        }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(store.token(id: token.id)?.boundDevice?.stableID, winners.first)
        XCTAssertEqual(AccessTokenStore(defaults: defaults).all, store.all)
    }

    func testStaleTokenCannotBindAfterRerollOrDeletion() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(defaults: defaults)
        let (token, _) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        let device = AccessToken.BoundDevice(stableID: "node-a", name: "Mac")
        store.add(token)
        store.modify(id: token.id) { $0.reroll() }
        XCTAssertThrowsError(try store.bind(token, to: device))
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
        store.remove(id: token.id)
        XCTAssertThrowsError(try store.bind(token, to: device))
    }
}

final class RemoteAccessBindingTests: XCTestCase {
    private let first = Tailscale.Peer(stableID: "node-a", deviceName: "Mac", userID: 1, isTagged: false)
    // The name is deliberately the same: only the stable ID identifies a node.
    private let other = Tailscale.Peer(stableID: "node-b", deviceName: "Mac", userID: 1, isTagged: false)

    private func makeStore() throws -> AccessTokenStore {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AccessTokenStore(defaults: defaults)
    }

    private func request(secret: String, method: String = "POST", sessionID: String? = nil) -> HTTPRequestMessage {
        var headers = [
            "Authorization": "Bearer \(secret)",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-11-25",
        ]
        if let sessionID { headers[HTTPHeaderName.sessionID] = sessionID }
        let body =
            if sessionID == nil {
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
            } else {
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
            }
        return HTTPRequestMessage(
            method: method,
            path: "/mcp",
            headers: headers,
            body: Data(body.utf8),
            keepAlive: true
        )
    }

    func testFirstSessionBindsAndSameNodeCanStartAnotherSession() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        store.add(token)
        let server = RemoteAccessServer(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
        let response = await server.respond(to: request(secret: secret), from: first)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(response.headers[HTTPHeaderName.sessionID])
        XCTAssertEqual(store.token(id: token.id)?.boundDevice, .init(stableID: first.stableID, name: first.deviceName))
        XCTAssertNotNil(store.token(id: token.id)?.lastUsedAt)

        var renamed = first
        renamed.deviceName = "Renamed Mac"
        let again = await server.respond(to: request(secret: secret), from: renamed)
        XCTAssertEqual(again.statusCode, 200)
        XCTAssertEqual(store.token(id: token.id)?.boundDevice?.name, renamed.deviceName)
        await server.closeSessions(forToken: token.id)
    }

    func testOtherNodeIsRejectedForNewAndExistingSessions() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        store.add(token)
        let server = RemoteAccessServer(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
        let initial = await server.respond(to: request(secret: secret), from: first)
        let sessionID = try XCTUnwrap(initial.headers[HTTPHeaderName.sessionID])
        let newSession = await server.respond(to: request(secret: secret), from: other)
        XCTAssertEqual(newSession.statusCode, 403)
        XCTAssertTrue(
            String(decoding: newSession.bodyData ?? Data(), as: UTF8.self).contains("bound to another device")
        )

        for method in ["POST", "GET", "DELETE"] {
            let response = await server.respond(
                to: request(secret: secret, method: method, sessionID: sessionID),
                from: other
            )
            XCTAssertEqual(response.statusCode, 403, method)
        }
        XCTAssertEqual(store.token(id: token.id)?.boundDevice?.stableID, first.stableID)
        for method in ["POST", "GET"] {
            let response = await server.respond(
                to: request(secret: secret, method: method, sessionID: sessionID),
                from: first
            )
            XCTAssertEqual(response.statusCode, 200, method)
        }
        // A rejected DELETE must leave the owner's session available.
        let accepted = await server.respond(
            to: request(secret: secret, method: "DELETE", sessionID: sessionID),
            from: first
        )
        XCTAssertEqual(accepted.statusCode, 200)
        await server.closeSessions(forToken: token.id)
    }

    func testConcurrentFirstSessionsAcceptOnlyOneNode() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Race", permissions: .readOnly)
        store.add(token)
        let barrier = SessionStartBarrier()
        let server = RemoteAccessServer(tokenStore: store) { _ in
            await barrier.wait()
            return MCP.Server(name: "test", version: "1")
        }
        let message = request(secret: secret)
        let responses = await withTaskGroup(of: (String, Int).self) { group in
            for peer in [first, other] {
                group.addTask { (peer.stableID, await server.respond(to: message, from: peer).statusCode) }
            }
            var responses: [(String, Int)] = []
            for await response in group { responses.append(response) }
            return responses
        }
        XCTAssertEqual(responses.map(\.1).sorted(), [200, 403])
        XCTAssertEqual(store.token(id: token.id)?.boundDevice?.stableID, responses.first { $0.1 == 200 }?.0)
        await server.closeSessions(forToken: token.id)
    }

    func testRejectedInitializationDoesNotBind() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        store.add(token)
        let server = RemoteAccessServer(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
        var message = request(secret: secret)
        message.headers["Content-Type"] = "text/plain"
        let response = await server.respond(to: message, from: first)
        XCTAssertEqual(response.statusCode, 415)
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
        XCTAssertNil(store.token(id: token.id)?.lastUsedAt)
        await server.closeSessions(forToken: token.id)
    }

    func testWhoisUsesStableIDAndRejectsMissingOrEmptyID() throws {
        let data = Data(#"{"Node":{"StableID":"node-a","ID":123,"User":1,"Hostinfo":{"Hostname":"Mac"}}}"#.utf8)
        XCTAssertEqual(try Tailscale.decodePeer(data, address: "100.64.0.1"), first)
        for node in [#"{"ID":123,"User":1}"#, #"{"StableID":"","User":1}"#] {
            XCTAssertThrowsError(try Tailscale.decodePeer(Data("{\"Node\":\(node)}".utf8), address: "100.64.0.1"))
        }
    }
}

/// Makes both requests reach session creation before either can claim the token.
private actor SessionStartBarrier {
    private var arrivals = 0
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        arrivals += 1
        if arrivals == 2 {
            waiting?.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
