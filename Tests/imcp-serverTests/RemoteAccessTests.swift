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
    private let first = TailnetPeer(stableID: "node-a", deviceName: "Mac", userID: 1, isTagged: false)
    // The name is deliberately the same: only the stable ID identifies a node.
    private let other = TailnetPeer(stableID: "node-b", deviceName: "Mac", userID: 1, isTagged: false)

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
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
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
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
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
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in
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
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
        var message = request(secret: secret)
        message.headers["Content-Type"] = "text/plain"
        let response = await server.respond(to: message, from: first)
        XCTAssertEqual(response.statusCode, 415)
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
        XCTAssertNil(store.token(id: token.id)?.lastUsedAt)
        await server.closeSessions(forToken: token.id)
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

final class TailnetStatusTests: XCTestCase {
    func testRunningNode() throws {
        let json = #"""
            {"BackendState":"Running","AuthURL":"","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],
             "Self":{"ID":"nSelf","HostName":"mac-imcp","DNSName":"mac-imcp.example.ts.net.",
                     "TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],"UserID":7},
             "Peer":{"nodekey:a":{"ID":"nPeer","HostName":"iPad","UserID":7},
                     "nodekey:b":{"ID":"","HostName":"Unnamed"}}}
            """#
        let status = try TailnetStatus(json: Data(json.utf8))
        let me = TailnetSelf(
            stableID: "nSelf",
            userID: 7,
            ipv4Address: "100.64.0.1",
            ipv6Address: "fd7a:115c:a1e0::1",
            dnsName: "mac-imcp.example.ts.net",
            isTagged: false
        )
        XCTAssertEqual(status.state, .running(me))
        XCTAssertEqual(status.peerNames, ["nPeer": "iPad"])
        XCTAssertEqual(me.hostNames, ["100.64.0.1", "mac-imcp.example.ts.net", "mac-imcp"])
    }

    func testTaggedNode() throws {
        let json = #"""
            {"BackendState":"Running","Self":{"ID":"nSelf","TailscaleIPs":["100.64.0.1"],"UserID":9,"Tags":["tag:server"]}}
            """#
        guard case .running(let me) = try TailnetStatus(json: Data(json.utf8)).state else {
            return XCTFail("Expected a running node")
        }
        XCTAssertTrue(me.isTagged)
        XCTAssertNil(me.dnsName)
    }

    func testLoginStates() throws {
        func state(_ json: String) throws -> TailnetStatus.State {
            try TailnetStatus(json: Data(json.utf8)).state
        }
        XCTAssertEqual(
            try state(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc"}"#),
            .needsLogin(URL(string: "https://login.tailscale.com/a/abc"))
        )
        XCTAssertEqual(try state(#"{"BackendState":"NeedsLogin","AuthURL":""}"#), .needsLogin(nil))
        XCTAssertEqual(try state(#"{"BackendState":"NeedsMachineAuth"}"#), .needsApproval)
        XCTAssertEqual(try state(#"{"BackendState":"Starting"}"#), .starting)
        XCTAssertEqual(try state(#"{"BackendState":"NoState"}"#), .starting)
        XCTAssertEqual(try state(#"{"BackendState":"Stopped"}"#), .stopped)
        // A running node without an identity or an IPv4 address isn't ready yet.
        XCTAssertEqual(try state(#"{"BackendState":"Running","Self":{"ID":"nSelf","UserID":1}}"#), .starting)
        XCTAssertEqual(
            try state(#"{"BackendState":"Running","Self":{"ID":"","TailscaleIPs":["100.64.0.1"],"UserID":1}}"#),
            .starting
        )
        XCTAssertThrowsError(try state(#"{"AuthURL":""}"#))
    }

    func testHostnames() {
        XCTAssertEqual(
            RemoteAccessServer.defaultHostname(computerName: "Mattt's MacBook Pro"),
            "mattts-macbook-pro-imcp"
        )
        XCTAssertEqual(
            RemoteAccessServer.defaultHostname(computerName: "Mattt\u{2019}s Mac mini"),
            "mattts-mac-mini-imcp"
        )
        XCTAssertEqual(RemoteAccessServer.defaultHostname(computerName: nil), "mac-imcp")
        XCTAssertEqual(RemoteAccessServer.defaultHostname(computerName: "日本"), "imcp")
        XCTAssertEqual(RemoteAccessServer.sanitizedHostname("  --Studio__Mac-- "), "studio-mac")
        XCTAssertNil(RemoteAccessServer.sanitizedHostname("---"))
        XCTAssertEqual(RemoteAccessServer.sanitizedHostname(String(repeating: "a", count: 70))?.count, 63)
    }
}

final class RemoteAccessAuthorizationTests: XCTestCase {
    private let me = TailnetSelf(
        stableID: "nSelf",
        userID: 1,
        ipv4Address: "100.64.0.1",
        dnsName: "mac-imcp.example.ts.net",
        isTagged: false
    )
    private let owner = TailnetPeer(stableID: "nOwner", deviceName: "iPad", userID: 1, isTagged: false)
    private let otherUser = TailnetPeer(stableID: "nOther", deviceName: "Laptop", userID: 2, isTagged: false)
    private let tagged = TailnetPeer(stableID: "nTagged", deviceName: "server", userID: 1, isTagged: true)

    func testAuthorizesOnlyUntaggedDevicesOfTheSameUser() {
        XCTAssertTrue(RemoteAccessServer.isAuthorized(owner, for: me))
        XCTAssertFalse(RemoteAccessServer.isAuthorized(otherUser, for: me))
        XCTAssertFalse(RemoteAccessServer.isAuthorized(tagged, for: me))
        var noID = owner
        noID.stableID = ""
        XCTAssertFalse(RemoteAccessServer.isAuthorized(noID, for: me))
        var taggedSelf = me
        taggedSelf.isTagged = true
        XCTAssertFalse(RemoteAccessServer.isAuthorized(owner, for: taggedSelf))
    }

    func testServesHTTPOverTheNodeToTheOwnerOnly() async throws {
        let node = FakeTailnetNode(
            state: .running(me),
            peers: ["100.64.0.2": owner, "100.64.0.3": otherUser, "100.64.0.4": tagged]
        )
        let (store, secret) = try makeStore()
        let server = makeServer(store: store, node: node)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil { node.listenedAddresses == ["100.64.0.1:4627"] }

        let accepted = try await node.connect(from: "100.64.0.2", sending: initializeRequest(secret: secret))
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200 OK\r\n"), accepted)
        XCTAssertTrue(accepted.lowercased().contains("mcp-session-id: "), accepted)
        XCTAssertEqual(store.all.first?.boundDevice, .init(stableID: "nOwner", name: "iPad"))

        for address in ["100.64.0.3", "100.64.0.4"] {
            let rejected = try await node.connect(from: address, sending: initializeRequest(secret: secret))
            XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), rejected)
        }
        // A device that whois doesn't know is rejected too.
        let unknown = try await node.connect(from: "100.64.0.9", sending: initializeRequest(secret: secret))
        XCTAssertTrue(unknown.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), unknown)

        await server.stop()
        XCTAssertEqual(node.closeCount, 1)
    }

    func testValidatesHostAgainstTheNode() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: ["100.64.0.2": owner])
        let (store, secret) = try makeStore()
        let server = makeServer(store: store, node: node)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil { !node.listenedAddresses.isEmpty }

        for host in ["mac-imcp.example.ts.net:4627", "100.64.0.1:4627", "mac-imcp:4627"] {
            let response = try await node.connect(
                from: "100.64.0.2",
                sending: initializeRequest(secret: secret, host: host)
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"), host)
        }
        for host in ["localhost:4627", "100.64.0.1:80", "evil.example:4627"] {
            let response = try await node.connect(
                from: "100.64.0.2",
                sending: initializeRequest(secret: secret, host: host)
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 421 "), host)
        }
        let origin = try await node.connect(
            from: "100.64.0.2",
            sending: initializeRequest(secret: secret, origin: "http://evil.example")
        )
        XCTAssertTrue(origin.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), origin)
        await server.stop()
    }

    func testLoginStatesAndLogOut() async throws {
        let loginURL = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/abc"))
        let node = FakeTailnetNode(state: .needsLogin(loginURL), peers: [:])
        let (store, _) = try makeStore()
        let configurations = ConfigurationLog()
        let server = RemoteAccessServer(
            tokenStore: store,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { configuration in
                configurations.append(configuration)
                return node
            },
            makeSessionServer: { _ in MCP.Server(name: "test", version: "1") }
        )
        let states = StateLog()
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil { states.last == .needsLogin(loginURL) }
        XCTAssertTrue(node.listenedAddresses.isEmpty)

        node.state = .running(me)
        try await waitUntil {
            if case .running(let endpoint) = states.last {
                return endpoint.url == "http://mac-imcp.example.ts.net:4627/mcp"
            }
            return false
        }

        await server.logOut()
        XCTAssertEqual(node.logoutCount, 1)
        XCTAssertTrue(states.all.contains(.loggingOut))
        // Logging out starts the node again, so that it gets a new login URL.
        try await waitUntil { configurations.all.count == 2 }
        XCTAssertEqual(configurations.all.map(\.hostname), ["mac-imcp", "mac-imcp"])
        XCTAssertEqual(
            configurations.all.map(\.stateDirectory.path),
            ["/nonexistent/Tailscale", "/nonexistent/Tailscale"]
        )

        await server.logIn(authKey: "tskey-auth-test")
        try await waitUntil { configurations.all.count == 3 }
        XCTAssertEqual(configurations.all.map(\.authKey), [nil, nil, "tskey-auth-test"])

        await server.stop()
        XCTAssertEqual(states.last, .off)
    }

    func testTaggedNodeDoesNotListen() async throws {
        var taggedSelf = me
        taggedSelf.isTagged = true
        let node = FakeTailnetNode(state: .running(taggedSelf), peers: [:])
        let (store, _) = try makeStore()
        let server = makeServer(store: store, node: node)
        let states = StateLog()
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil {
            if case .failed = states.last { true } else { false }
        }
        XCTAssertTrue(node.listenedAddresses.isEmpty)
        await server.stop()
    }

    // MARK: Helpers

    private func makeStore() throws -> (AccessTokenStore, String) {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(defaults: defaults)
        let (token, secret) = AccessToken.make(name: "iPad", permissions: .readOnly)
        store.add(token)
        return (store, secret)
    }

    private func makeServer(store: AccessTokenStore, node: FakeTailnetNode) -> RemoteAccessServer {
        RemoteAccessServer(
            tokenStore: store,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { _ in node },
            makeSessionServer: { _ in MCP.Server(name: "test", version: "1") }
        )
    }

    private func initializeRequest(
        secret: String,
        host: String = "mac-imcp.example.ts.net:4627",
        origin: String? = nil
    ) -> Data {
        let body =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        var head = [
            "POST /mcp HTTP/1.1",
            "Host: \(host)",
            "Authorization: Bearer \(secret)",
            "Accept: application/json, text/event-stream",
            "Content-Type: application/json",
            "MCP-Protocol-Version: 2025-11-25",
            "Content-Length: \(body.utf8.count)",
        ]
        if let origin { head.append("Origin: \(origin)") }
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }
}

/// Waits for a condition that another task makes true.
private func waitUntil(
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out", file: file, line: line)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

extension RemoteAccessServer {
    /// A server whose node can't start, for tests that call `respond(to:from:)` directly.
    static func forTesting(
        tokenStore: AccessTokenStore,
        makeSessionServer: @escaping @Sendable (UUID) async -> MCP.Server?
    ) -> RemoteAccessServer {
        RemoteAccessServer(
            tokenStore: tokenStore,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { _ in throw CancellationError() },
            makeSessionServer: makeSessionServer
        )
    }
}

/// A list that tasks append to and tests read.
private final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    var all: [Element] { lock.withLock { elements } }
    var last: Element? { lock.withLock { elements.last } }

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }
}

private typealias StateLog = LockedList<RemoteAccessServer.State>
private typealias ConfigurationLog = LockedList<TailnetNodeConfiguration>

/// A node on a pretend tailnet, with peers at fixed addresses.
private final class FakeTailnetNode: TailnetNode, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: TailnetStatus.State
    private let peers: [String: TailnetPeer]
    private var listeners: [FakeTailnetListener] = []
    private var _listenedAddresses: [String] = []
    private var _logoutCount = 0
    private var _closeCount = 0

    init(state: TailnetStatus.State, peers: [String: TailnetPeer]) {
        _state = state
        self.peers = peers
    }

    var state: TailnetStatus.State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var listenedAddresses: [String] { lock.withLock { _listenedAddresses } }
    var logoutCount: Int { lock.withLock { _logoutCount } }
    var closeCount: Int { lock.withLock { _closeCount } }

    func status() async throws -> TailnetStatus {
        TailnetStatus(state: state)
    }

    func whois(_ address: String) async throws -> TailnetPeer {
        guard let peer = peers[address] else { throw URLError(.cannotFindHost) }
        return peer
    }

    func listen(on address: String, port: UInt16) async throws -> any TailnetListener {
        let listener = FakeTailnetListener()
        lock.withLock {
            listeners.append(listener)
            _listenedAddresses.append("\(address):\(port)")
        }
        return listener
    }

    func logout() async throws {
        lock.withLock {
            _logoutCount += 1
            _state = .needsLogin(nil)
        }
    }

    func close() async {
        let listeners = lock.withLock {
            _closeCount += 1
            return self.listeners
        }
        for listener in listeners { listener.finish() }
    }

    /// Opens a connection from a peer, sends the bytes,
    /// and returns everything that the server sends before it closes the connection.
    func connect(from address: String, sending request: Data) async throws -> String {
        let listener = try XCTUnwrap(lock.withLock { listeners.last })
        let connection = FakeTailnetConnection(remoteAddress: address, request: request)
        listener.yield(connection)
        return String(decoding: await connection.output(), as: UTF8.self)
    }
}

private final class FakeTailnetListener: TailnetListener, @unchecked Sendable {
    private let stream: AsyncStream<FakeTailnetConnection>
    private let continuation: AsyncStream<FakeTailnetConnection>.Continuation
    private let lock = NSLock()
    private var iterator: AsyncStream<FakeTailnetConnection>.AsyncIterator?

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func yield(_ connection: FakeTailnetConnection) { continuation.yield(connection) }
    func finish() { continuation.finish() }

    func accept() async throws -> any TailnetConnection {
        // Only the server's accept loop calls this, one call at a time.
        var iterator = lock.withLock { self.iterator }
        let next = await iterator?.next()
        lock.withLock { self.iterator = iterator }
        guard let next else { throw CancellationError() }
        return next
    }
}

/// A connection whose peer sends one request, then closes its side.
private final class FakeTailnetConnection: TailnetConnection, @unchecked Sendable {
    let remoteAddress: String?
    private let lock = NSLock()
    private var inbound: Data?
    private var sent = Data()
    private var isClosed = false
    private var closeWaiters: [CheckedContinuation<Data, Never>] = []

    init(remoteAddress: String, request: Data) {
        self.remoteAddress = remoteAddress
        inbound = request
    }

    func receive(timeout: Duration) async throws -> Data {
        lock.withLock {
            defer { inbound = nil }
            return inbound ?? Data()
        }
    }

    func send(_ data: Data, timeout: Duration) async throws {
        try lock.withLock {
            guard !isClosed else { throw CancellationError() }
            sent.append(data)
        }
    }

    func close() async {
        let (waiters, data) = lock.withLock {
            isClosed = true
            defer { closeWaiters.removeAll() }
            return (closeWaiters, sent)
        }
        for waiter in waiters { waiter.resume(returning: data) }
    }

    /// The bytes that the server sent, once it closes the connection.
    func output() async -> Data {
        await withCheckedContinuation { continuation in
            let data: Data? = lock.withLock {
                if isClosed { return sent }
                closeWaiters.append(continuation)
                return nil
            }
            if let data { continuation.resume(returning: data) }
        }
    }
}
