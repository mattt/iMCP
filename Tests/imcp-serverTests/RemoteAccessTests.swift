import Foundation
import JSONSchema
import MCP
import Network
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
        let storage = InMemoryAccessTokenStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AccessTokenStore(storage: storage, defaults: defaults)
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        try store.add(token)
        XCTAssertEqual(store.token(secret: secret)?.id, token.id)
        XCTAssertNil(store.token(secret: "imcp_wrong"))
        XCTAssertNil(store.token(secret: "wrong"))

        // A new store reads the same tokens.
        XCTAssertEqual(AccessTokenStore(storage: storage, defaults: defaults).all, [token])
        XCTAssertNil(defaults.object(forKey: "remoteAccessTokens"))

        try store.modify(id: token.id) { $0.permissions = .custom(["write"]) }
        XCTAssertEqual(
            AccessTokenStore(storage: storage, defaults: defaults).token(id: token.id)?.permissions,
            .custom(["write"])
        )

        try store.remove(id: token.id)
        XCTAssertNil(store.token(secret: secret))
        XCTAssertTrue(AccessTokenStore(storage: storage, defaults: defaults).all.isEmpty)
    }

    func testRerollReplacesSecretAndKeepsSettings() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AccessTokenStore(storage: storage, defaults: defaults)
        var (token, oldSecret) = AccessToken.make(name: "Laptop", permissions: .allTools)
        token.lastUsedAt = Date()
        token.lastUsedDevice = "MacBook Pro"
        token.boundDevice = .init(stableID: "node-a", name: "MacBook Pro")
        try store.add(token)

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
        XCTAssertEqual(AccessTokenStore(storage: storage, defaults: defaults).all, store.all)
    }

    func testDiscardsLegacyTokensWithoutMigration() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(
            #"[{"id":"BFA1562C-E2D4-4914-9BD3-0487301CC00B","name":"Old token","permissions":{"readOnly":{}},"secretHash":"AQID","createdAt":0,"lastUsedAt":1,"lastUsedDevice":"Old Mac"}]"#
                .utf8
        )
        defaults.set(data, forKey: "remoteAccessTokens")
        let (savedToken, _) = AccessToken.make(name: "Keychain token", permissions: .allTools)
        try storage.save([savedToken])
        let store = AccessTokenStore(storage: storage, defaults: defaults)
        XCTAssertEqual(store.all, [savedToken])
        XCTAssertNil(defaults.object(forKey: "remoteAccessTokens"))
    }

    func testConcurrentBindingPersistsOnlyOneNode() async throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(storage: storage, defaults: defaults)
        let (token, _) = AccessToken.make(name: "Race", permissions: .readOnly)
        try store.add(token)

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
        XCTAssertEqual(AccessTokenStore(storage: storage, defaults: defaults).all, store.all)
    }

    func testStaleTokenCannotBindAfterRerollOrDeletion() throws {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(storage: storage, defaults: defaults)
        let (token, _) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        let device = AccessToken.BoundDevice(stableID: "node-a", name: "Mac")
        try store.add(token)
        try store.modify(id: token.id) { $0.reroll() }
        XCTAssertThrowsError(try store.bind(token, to: device))
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
        try store.remove(id: token.id)
        XCTAssertThrowsError(try store.bind(token, to: device))
    }
}

final class AccessTokenStorageFailureTests: XCTestCase {
    private func makeStore(_ storage: FailingAccessTokenStorage) throws -> AccessTokenStore {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AccessTokenStore(storage: storage, defaults: defaults)
    }

    func testUnreadableStorageIsUnavailableUntilARead() throws {
        let (saved, secret) = AccessToken.make(name: "Saved", permissions: .readOnly)
        let storage = FailingAccessTokenStorage(tokens: [saved])
        storage.failsLoad = true
        let store = try makeStore(storage)

        XCTAssertNotNil(store.storageError)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(store.token(secret: secret))
        let (other, _) = AccessToken.make(name: "Other", permissions: .readOnly)
        XCTAssertThrowsError(try store.add(other)) { error in
            guard case AccessTokenStore.StorageError.unavailable = error else {
                return XCTFail("Expected unavailable storage, got \(error)")
            }
        }
        // A change must not replace the tokens that iMCP couldn't read.
        XCTAssertEqual(storage.tokens, [saved])
        XCTAssertEqual(storage.saveCount, 0)

        storage.failsLoad = false
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.token(secret: secret)?.id, saved.id)
        try store.add(other)
        XCTAssertEqual(storage.tokens, [saved, other])
    }

    func testFailedBindingLeavesTokenUnbound() throws {
        let storage = FailingAccessTokenStorage()
        let store = try makeStore(storage)
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        try store.add(token)

        storage.failsSave = true
        XCTAssertThrowsError(try store.bind(token, to: .init(stableID: "node-a", name: "Mac"))) { error in
            guard case AccessTokenStore.StorageError.saveFailed = error else {
                return XCTFail("Expected a save failure, got \(error)")
            }
        }
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
        XCTAssertNil(storage.tokens.first?.boundDevice)
        // A failed binding doesn't suspend the token.
        XCTAssertEqual(store.token(secret: secret)?.id, token.id)
    }

    func testFailedRevocationsAndEditsSuspendTheToken() throws {
        let storage = FailingAccessTokenStorage()
        let store = try makeStore(storage)
        let (deleted, deletedSecret) = AccessToken.make(name: "Deleted", permissions: .allTools)
        let (rerolled, rerolledSecret) = AccessToken.make(name: "Rerolled", permissions: .allTools)
        let (edited, editedSecret) = AccessToken.make(name: "Edited", permissions: .allTools)
        for token in [deleted, rerolled, edited] { try store.add(token) }

        storage.failsSave = true
        XCTAssertThrowsError(try store.remove(id: deleted.id))
        XCTAssertThrowsError(try store.modify(id: rerolled.id) { $0.reroll() })
        XCTAssertThrowsError(try store.modify(id: edited.id) { $0.permissions = .readOnly })

        // The saved list is unchanged, but none of the tokens work.
        XCTAssertEqual(storage.tokens, [deleted, rerolled, edited])
        XCTAssertEqual(store.all, [deleted, rerolled, edited])
        for (token, secret) in [(deleted, deletedSecret), (rerolled, rerolledSecret), (edited, editedSecret)] {
            XCTAssertNil(store.token(secret: secret), token.name)
            XCTAssertNil(store.token(id: token.id), token.name)
            XCTAssertThrowsError(try store.bind(token, to: .init(stableID: "node-a", name: "Mac")), token.name)
        }

        storage.failsSave = false
        try store.modify(id: edited.id) { $0.permissions = .readOnly }
        XCTAssertEqual(store.token(secret: editedSecret)?.permissions, .readOnly)
        try store.remove(id: deleted.id)
        XCTAssertEqual(storage.tokens.map(\.id), [rerolled.id, edited.id])
        XCTAssertNil(store.token(secret: rerolledSecret))
    }

    func testUnsavedBindingRejectsTheSession() async throws {
        let storage = FailingAccessTokenStorage()
        let store = try makeStore(storage)
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        try store.add(token)
        storage.failsSave = true
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in MCP.Server(name: "test", version: "1") }
        let body =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        let message = HTTPRequestMessage(
            method: "POST",
            path: "/mcp",
            headers: [
                "Authorization": "Bearer \(secret)",
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-11-25",
            ],
            body: Data(body.utf8),
            keepAlive: true
        )
        let peer = TailnetPeer(stableID: "node-a", deviceName: "Mac", userID: 1, isTagged: false)
        let response = await server.respond(to: message, from: peer)
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertNil(response.headers[HTTPHeaderName.sessionID])
        XCTAssertNil(store.token(id: token.id)?.boundDevice)
    }
}

/// Storage that can fail to read or save.
private final class FailingAccessTokenStorage: AccessTokenStorage, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _tokens: [AccessToken]
    private var _failsLoad = false
    private var _failsSave = false
    private var _saveCount = 0

    init(tokens: [AccessToken] = []) {
        _tokens = tokens
    }

    var tokens: [AccessToken] { lock.withLock { _tokens } }
    var saveCount: Int { lock.withLock { _saveCount } }
    var failsLoad: Bool {
        get { lock.withLock { _failsLoad } }
        set { lock.withLock { _failsLoad = newValue } }
    }
    var failsSave: Bool {
        get { lock.withLock { _failsSave } }
        set { lock.withLock { _failsSave = newValue } }
    }

    func load() throws -> [AccessToken] {
        try lock.withLock {
            if _failsLoad { throw Failure() }
            return _tokens
        }
    }

    func save(_ tokens: [AccessToken]) throws {
        try lock.withLock {
            if _failsSave { throw Failure() }
            _saveCount += 1
            _tokens = tokens
        }
    }
}

final class RemoteAccessBindingTests: XCTestCase {
    private let first = TailnetPeer(stableID: "node-a", deviceName: "Mac", userID: 1, isTagged: false)
    // The name is deliberately the same: only the stable ID identifies a node.
    private let other = TailnetPeer(stableID: "node-b", deviceName: "Mac", userID: 1, isTagged: false)

    private func makeStore() throws -> AccessTokenStore {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AccessTokenStore(storage: storage, defaults: defaults)
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
        try store.add(token)
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
        try store.add(token)
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
        try store.add(token)
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

    func testConcurrentStartsStayWithinTheSessionLimit() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        try store.add(token)
        let limit = RemoteAccessServer.maximumSessions
        let barrier = SessionStartBarrier(count: limit)
        let server = RemoteAccessServer.forTesting(tokenStore: store) { _ in
            await barrier.wait()
            return MCP.Server(name: "test", version: "1")
        }
        let message = request(secret: secret)
        let peer = first
        let statuses = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ... limit {
                group.addTask { await server.respond(to: message, from: peer).statusCode }
            }
            var statuses: [Int] = []
            for await status in group { statuses.append(status) }
            return statuses
        }
        // Every session is still starting when the last request arrives, so none can make room.
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, limit)
        XCTAssertEqual(statuses.filter { $0 == 503 }.count, 1)
        await server.closeSessions(forToken: token.id)
    }

    func testRejectedInitializationDoesNotBind() async throws {
        let store = try makeStore()
        let (token, secret) = AccessToken.make(name: "Laptop", permissions: .readOnly)
        try store.add(token)
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

/// Holds session starts until a number of them arrive, or until the test opens it.
private actor SessionStartBarrier {
    private let count: Int
    private var arrivals = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// By default, makes two requests reach session creation before either can claim the token.
    init(count: Int = 2) {
        self.count = count
    }

    var arrived: Int { arrivals }

    func wait() async {
        arrivals += 1
        if arrivals >= count {
            open()
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func open() {
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
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

    func testStateNamesLeaveOutLoginURLs() throws {
        let url = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/secret-login-path"))
        let state = RemoteAccessServer.State.needsLogin(url)
        XCTAssertEqual(state.name, "needsLogin")
        XCTAssertFalse(state.name.contains("secret-login-path"))
        XCTAssertEqual(RemoteAccessServer.State.failed("details").name, "failed")
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

    func testChecksTheDeviceForEachRequestOnAnOpenConnection() async throws {
        let changes: [(String, TailnetPeer)] = [
            ("another user", otherUser),
            ("tags", TailnetPeer(stableID: owner.stableID, deviceName: "iPad", userID: 1, isTagged: true)),
        ]
        for (change, changed) in changes {
            let node = FakeTailnetNode(state: .running(me), peers: ["100.64.0.2": owner])
            let (store, secret) = try makeStore()
            // Every request asks whois again.
            let server = makeServer(store: store, node: node, peerLifetime: 0)
            await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
            try await waitUntil { !node.listenedAddresses.isEmpty }

            let connection = try node.open(from: "100.64.0.2")
            connection.write(initializeRequest(secret: secret))
            try await waitUntil { connection.output.contains("0\r\n\r\n") }
            XCTAssertTrue(connection.output.hasPrefix("HTTP/1.1 200 OK\r\n"), change)
            let sessionID = try XCTUnwrap(Self.sessionID(in: connection.output), change)

            node.setPeer(changed, at: "100.64.0.2")
            connection.write(pingRequest(secret: secret, sessionID: sessionID))
            try await waitUntil { connection.isClosed }
            XCTAssertTrue(connection.output.contains("HTTP/1.1 403 Forbidden\r\n"), change)

            // The session ended, so the device can't use it after it gets access back.
            node.setPeer(owner, at: "100.64.0.2")
            let again = try await node.connect(
                from: "100.64.0.2",
                sending: pingRequest(secret: secret, sessionID: sessionID)
            )
            XCTAssertTrue(again.hasPrefix("HTTP/1.1 404 Not Found\r\n"), "\(change): \(again)")
            await server.stop()
        }
    }

    func testSessionThatFinishesStartingAfterStopIsRejected() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: ["100.64.0.2": owner])
        let (store, secret) = try makeStore()
        let barrier = SessionStartBarrier(count: .max)
        let server = RemoteAccessServer(
            tokenStore: store,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { _ in node },
            makeSessionServer: { _ in
                await barrier.wait()
                return MCP.Server(name: "test", version: "1")
            }
        )
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil { !node.listenedAddresses.isEmpty }

        let request = initializeRequest(secret: secret)
        let pending = Task { try await node.connect(from: "100.64.0.2", sending: request) }
        try await waitUntil { await barrier.arrived == 1 }
        await server.stop()
        await barrier.open()

        let response = try await pending.value
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503 "), response)
        XCTAssertFalse(response.lowercased().contains("mcp-session-id"), response)
        XCTAssertNil(store.all.first?.boundDevice)
        XCTAssertNil(store.all.first?.lastUsedAt)
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

    // MARK: Funnel

    private func makeFunnelServer(
        store: AccessTokenStore,
        node: FakeTailnetNode,
        local: FakeLocalListener,
        oauth: OAuthAuthority = OAuthAuthority(storage: InMemoryOAuthGrantStorage())
    ) -> RemoteAccessServer {
        RemoteAccessServer(
            tokenStore: store,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { _ in node },
            makeSessionServer: { _ in MCP.Server(name: "test", version: "1") },
            makeLocalListener: { local },
            oauth: oauth
        )
    }

    func testFunnelIsOffUnlessEnabled() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let states = StateLog()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp"))
        try await waitUntil { node.disableFunnelCount == 1 }
        try await waitUntil {
            if case .running = states.last { return true }
            return false
        }

        XCTAssertEqual(node.funnelPorts, [])
        guard case .running(let endpoint) = states.last else { return XCTFail("Expected running") }
        XCTAssertEqual(endpoint.funnel, .off)
        await server.stop()
    }

    func testFunnelRequestsNeedATokenWhateverTheirAddress() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: ["127.0.0.1": owner])
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let states = StateLog()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { node.funnelPorts == [54321] }
        try await waitUntil {
            if case .running(let endpoint) = states.last, case .active = endpoint.funnel { return true }
            return false
        }
        guard case .running(let endpoint) = states.last else { return XCTFail("Expected running") }
        XCTAssertEqual(endpoint.funnel, .active(url: "https://mac-imcp.example.ts.net/mcp"))

        // A good token works, and does not bind the token to a device.
        let accepted = await local.connect(sending: initializeRequest(secret: secret, host: "mac-imcp.example.ts.net"))
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200 OK\r\n"), accepted)
        XCTAssertNil(store.all.first?.boundDevice)

        // No token fails, even though the tailnet would trust a device at this address.
        let noToken = await local.connect(sending: initializeRequest(secret: "", host: "mac-imcp.example.ts.net"))
        XCTAssertTrue(noToken.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), noToken)
        XCTAssertTrue(noToken.contains("Connection: close"), noToken)
        let wrong = await local.connect(
            sending: initializeRequest(secret: AccessToken.makeSecret(), host: "mac-imcp.example.ts.net")
        )
        XCTAssertTrue(wrong.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), wrong)

        // Only the public name is accepted, without the tailnet port.
        for host in ["mac-imcp.example.ts.net:443", "mac-imcp.example.ts.net"] {
            let response = await local.connect(sending: initializeRequest(secret: secret, host: host))
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"), host)
        }
        for host in ["mac-imcp.example.ts.net:4627", "127.0.0.1", "100.64.0.1", "evil.example"] {
            let response = await local.connect(sending: initializeRequest(secret: secret, host: host))
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 421 "), "\(host): \(response)")
        }
        let badOrigin = await local.connect(
            sending: initializeRequest(
                secret: secret,
                host: "mac-imcp.example.ts.net",
                origin: "http://mac-imcp.example.ts.net"
            )
        )
        XCTAssertTrue(badOrigin.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), badOrigin)
        let goodOrigin = await local.connect(
            sending: initializeRequest(
                secret: secret,
                host: "mac-imcp.example.ts.net",
                origin: "https://mac-imcp.example.ts.net"
            )
        )
        XCTAssertTrue(goodOrigin.hasPrefix("HTTP/1.1 200 OK\r\n"), goodOrigin)

        await server.stop()
        // The node clears Funnel when it starts, and again when it stops,
        // so that it doesn't come back on the next start.
        XCTAssertEqual(node.disableFunnelCount, 2)
        XCTAssertEqual(local.shutdownCount, 1)
    }

    func testFunnelRejectsTokensBoundToTailnetDevices() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: ["100.64.0.2": owner])
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { node.funnelPorts == [54321] }
        try await waitUntil { !node.listenedAddresses.isEmpty }

        // The first tailnet session binds the token to the iPad.
        let bound = try await node.connect(from: "100.64.0.2", sending: initializeRequest(secret: secret))
        XCTAssertTrue(bound.hasPrefix("HTTP/1.1 200 OK\r\n"), bound)
        XCTAssertNotNil(store.all.first?.boundDevice)

        try await waitUntil {
            await server.hasFunnelHost
        }
        let response = await local.connect(sending: initializeRequest(secret: secret, host: "mac-imcp.example.ts.net"))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), response)
        await server.stop()
    }

    func testFunnelFailureLeavesTheTailnetServerRunning() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        node.funnelError = URLError(.userAuthenticationRequired)
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let states = StateLog()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil {
            if case .running(let endpoint) = states.last, case .failed = endpoint.funnel { return true }
            return false
        }
        XCTAssertEqual(node.listenedAddresses, ["100.64.0.1:4627"])
        XCTAssertEqual(local.shutdownCount, 1)
        await server.stop()
    }

    func testFunnelBlocksRepeatedBadTokensButNotGoodOnes() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { node.funnelPorts == [54321] }
        try await waitUntil { await server.hasFunnelHost }

        var statuses: [String] = []
        for _ in 0 ..< FailedAuthLimiter().maximumFailures + 2 {
            let response = await local.connect(
                sending: initializeRequest(secret: "imcp_bad", host: "mac-imcp.example.ts.net")
            )
            statuses.append(String(response.prefix(12)))
        }
        XCTAssertEqual(statuses.first, "HTTP/1.1 401")
        XCTAssertEqual(statuses.last, "HTTP/1.1 429")

        let good = await local.connect(sending: initializeRequest(secret: secret, host: "mac-imcp.example.ts.net"))
        XCTAssertTrue(good.hasPrefix("HTTP/1.1 200 OK\r\n"), good)
        await server.stop()
    }

    func testPublicUnauthorizedResponsePointsToTheResourceMetadata() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { await server.hasFunnelHost }

        let metadata = #"resource_metadata="https://mac-imcp.example.ts.net/.well-known/oauth-protected-resource""#
        let none = await local.connect(sending: rawRequest("POST", "/mcp", host: "mac-imcp.example.ts.net"))
        XCTAssertTrue(none.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), none)
        XCTAssertTrue(none.contains("WWW-Authenticate: Bearer realm=\"iMCP\", \(metadata)"), none)
        XCTAssertFalse(none.contains("invalid_token"), none)
        // A token that iMCP doesn't accept says so.
        let bad = await local.connect(
            sending: initializeRequest(secret: "imcpat_unknown", host: "mac-imcp.example.ts.net")
        )
        XCTAssertTrue(bad.contains(#"error="invalid_token""#), bad)
        XCTAssertTrue(bad.contains(metadata), bad)
        await server.stop()
    }

    func testOAuthPathsNeedNoTokenButFollowHostAndOriginRules() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { await server.hasFunnelHost }

        let host = "mac-imcp.example.ts.net"
        let metadata = await local.connect(
            sending: rawRequest("GET", "/.well-known/oauth-protected-resource", host: host)
        )
        XCTAssertTrue(metadata.hasPrefix("HTTP/1.1 200 OK\r\n"), metadata)
        XCTAssertTrue(metadata.contains("\"authorization_servers\":[\"https://\(host)\"]"), metadata)
        let issuer = await local.connect(
            sending: rawRequest("GET", "/.well-known/oauth-authorization-server", host: host)
        )
        XCTAssertTrue(issuer.contains("\"code_challenge_methods_supported\":[\"S256\"]"), issuer)

        for wrongHost in ["evil.example", "127.0.0.1", "mac-imcp.example.ts.net:4627"] {
            let response = await local.connect(
                sending: rawRequest("GET", "/.well-known/oauth-authorization-server", host: wrongHost)
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 421 "), "\(wrongHost): \(response)")
        }
        let crossSite = await local.connect(
            sending: rawRequest(
                "POST",
                "/token",
                host: host,
                origin: "https://evil.example",
                body: "grant_type=refresh_token&client_id=x&refresh_token=y"
            )
        )
        XCTAssertTrue(crossSite.hasPrefix("HTTP/1.1 403 Forbidden\r\n"), crossSite)
        await server.stop()
    }

    func testOAuthAccessTokenReachesMCPUntilRevoked() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let authority = OAuthAuthority(storage: InMemoryOAuthGrantStorage())
        let server = makeFunnelServer(store: store, node: node, local: local, oauth: authority)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { await server.hasFunnelHost }

        let host = "mac-imcp.example.ts.net"
        let client = try authority.register(name: "Claude", redirectURIs: ["https://claude.ai/cb"])
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let pending = try XCTUnwrap(
            authority.beginPending(
                client: client,
                redirectURI: "https://claude.ai/cb",
                state: nil,
                challenge: challenge,
                resource: "https://\(host)/mcp"
            )
        )
        authority.setDecision(.approved(readOnly: true), for: pending.id)
        let secret = authority.takePollSecret(forPending: pending.id)
        guard case .approved(_, _, let code) = authority.outcome(ofPending: pending.id, pollSecret: secret) else {
            return XCTFail("Expected approval")
        }
        let tokens = try authority.exchange(
            code: code,
            clientID: client.id,
            redirectURI: "https://claude.ai/cb",
            verifier: verifier,
            resource: "https://\(host)/mcp",
            host: host
        )

        let accepted = await local.connect(sending: initializeRequest(secret: tokens.accessToken, host: host))
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200 OK\r\n"), accepted)
        // A token for this endpoint doesn't open the tailnet listener, which only knows iMCP tokens.
        XCTAssertNil(store.token(secret: tokens.accessToken))

        try authority.revoke(id: try XCTUnwrap(authority.allGrants.first).id)
        let revoked = await local.connect(sending: initializeRequest(secret: tokens.accessToken, host: host))
        XCTAssertTrue(revoked.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), revoked)
        await server.stop()
    }

    func testFunnelConnectionClosesWhenTheRequestTakesTooLong() async throws {
        // A client that sends a byte at a time never goes idle, so only the deadline ends it.
        let connection = TrickleConnection()
        let handled = LockedList<String>()
        let http = HTTPServerConnection(
            connection,
            limits: .publicInternet,
            idleTimeout: .seconds(60),
            requestDeadline: .milliseconds(300)
        )
        let started = ContinuousClock.now
        await http.serve(
            { request in
                handled.append(request.path)
                return (.mcp(.error(statusCode: 400, .invalidRequest("x"))), keepAlive: false)
            },
            streamEnded: { _ in }
        )
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertTrue(handled.all.isEmpty)
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(FunnelPolicy.requestDeadline, .seconds(15))
    }

    func testStoppingDuringFunnelEnableClearsWhatItSaved() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        node.holdFunnelEnable()
        let (store, _) = try makeStore()
        let local = FakeLocalListener()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        try await waitUntil { node.funnelEvents.contains("enable-started") }

        let stopping = Task { await server.stop() }
        try await Task.sleep(for: .milliseconds(150))
        node.releaseFunnelEnable()
        await stopping.value

        // The saved configuration is cleared after the pending enable finishes, not before.
        XCTAssertEqual(node.funnelEvents, ["disable", "enable-started", "enable-finished", "disable"])
    }

    func testFunnelIsClearedEvenWhenTheNodeReturnsEarly() async throws {
        let tagged = TailnetSelf(
            stableID: "n1",
            userID: 1,
            ipv4Address: "100.64.0.1",
            ipv6Address: nil,
            dnsName: "mac-imcp.example.ts.net",
            isTagged: true
        )
        let node = FakeTailnetNode(state: .running(tagged), peers: [:])
        let (store, _) = try makeStore()
        let server = makeFunnelServer(store: store, node: node, local: FakeLocalListener())
        await server.configure(.init(isEnabled: true, port: 4627, hostname: "mac-imcp", funnelEnabled: true))
        // The node returns early because it's tagged, but the old configuration is already cleared.
        try await waitUntil { node.disableFunnelCount == 1 }
        XCTAssertEqual(node.funnelPorts, [])
        await server.stop()
    }

    func testCloudflareHostStartsSharedLoopbackWithoutTailscale() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let loopbackUpdates = LockedList<RemoteAccessServer.PublicLoopbackState>()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.setPublicLoopbackHandler { loopbackUpdates.append($0) }

        await server.configure(
            .init(
                isEnabled: false,
                port: 4627,
                hostname: "mac-imcp",
                funnelEnabled: false,
                cloudflareHostname: "imcp.example.com"
            )
        )

        try await waitUntil { await server.publicLoopbackPort == 54321 }
        XCTAssertTrue(node.listenedAddresses.isEmpty)
        XCTAssertEqual(loopbackUpdates.last, .listening(port: 54321))
        let hosts = await server.publicHosts
        XCTAssertEqual(hosts, ["imcp.example.com"])

        let ok = await local.connect(sending: initializeRequest(secret: secret, host: "imcp.example.com"))
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"), ok)

        let metadata = await local.connect(
            sending: rawRequest("GET", "/.well-known/oauth-protected-resource", host: "imcp.example.com")
        )
        XCTAssertTrue(metadata.contains(#""resource":"https://imcp.example.com/mcp""#), metadata)

        let rejected = await local.connect(sending: initializeRequest(secret: secret, host: "evil.example"))
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 421 "), rejected)

        await server.stop()
        XCTAssertEqual(local.shutdownCount, 1)
        XCTAssertEqual(loopbackUpdates.last, .stopped)
    }

    func testSharedLoopbackServesBothTailscaleFunnelAndCloudflareWithIsolatedOAuth() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let authority = OAuthAuthority(storage: InMemoryOAuthGrantStorage())
        let server = makeFunnelServer(store: store, node: node, local: local, oauth: authority)

        await server.configure(
            .init(
                isEnabled: true,
                port: 4627,
                hostname: "mac-imcp",
                funnelEnabled: true,
                cloudflareHostname: "imcp.example.net"
            )
        )

        try await waitUntil {
            await server.publicHosts == ["mac-imcp.example.ts.net", "imcp.example.net"]
        }

        // Both public hosts work with Bearer access tokens.
        for host in ["mac-imcp.example.ts.net", "imcp.example.net"] {
            let response = await local.connect(sending: initializeRequest(secret: secret, host: host))
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(host): \(response)")
        }

        // Each host advertises its own OAuth resource URL.
        let cfMeta = await local.connect(
            sending: rawRequest("GET", "/.well-known/oauth-protected-resource", host: "imcp.example.net")
        )
        XCTAssertTrue(cfMeta.contains(#""resource":"https://imcp.example.net/mcp""#), cfMeta)
        let tsMeta = await local.connect(
            sending: rawRequest("GET", "/.well-known/oauth-protected-resource", host: "mac-imcp.example.ts.net")
        )
        XCTAssertTrue(tsMeta.contains(#""resource":"https://mac-imcp.example.ts.net/mcp""#), tsMeta)

        // An OAuth token minted for the Cloudflare host works only on that host, not on the Tailscale host.
        let client = try authority.register(name: "Claude", redirectURIs: ["https://claude.ai/cb"])
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let cfHost = "imcp.example.net"
        let pending = try XCTUnwrap(
            authority.beginPending(
                client: client,
                redirectURI: "https://claude.ai/cb",
                state: nil,
                challenge: challenge,
                resource: "https://\(cfHost)/mcp"
            )
        )
        authority.setDecision(.approved(readOnly: true), for: pending.id)
        let pollSecret = authority.takePollSecret(forPending: pending.id)
        guard case .approved(_, _, let code) = authority.outcome(ofPending: pending.id, pollSecret: pollSecret) else {
            return XCTFail("Expected OAuth approval")
        }
        let tokens = try authority.exchange(
            code: code,
            clientID: client.id,
            redirectURI: "https://claude.ai/cb",
            verifier: verifier,
            resource: "https://\(cfHost)/mcp",
            host: cfHost
        )

        let cfAccepted = await local.connect(sending: initializeRequest(secret: tokens.accessToken, host: cfHost))
        XCTAssertTrue(cfAccepted.hasPrefix("HTTP/1.1 200 OK\r\n"), cfAccepted)

        let tsRejected = await local.connect(
            sending: initializeRequest(secret: tokens.accessToken, host: "mac-imcp.example.ts.net")
        )
        XCTAssertTrue(tsRejected.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), tsRejected)

        await server.stop()
    }

    func testFunnelFailureKeepsSharedLoopbackAliveWhenCloudflareIsActive() async throws {
        let node = FakeTailnetNode(state: .running(me), peers: [:])
        node.funnelError = URLError(.userAuthenticationRequired)
        let (store, secret) = try makeStore()
        let local = FakeLocalListener()
        let states = StateLog()
        let server = makeFunnelServer(store: store, node: node, local: local)
        await server.setHandlers(state: { states.append($0) }, tokenUsage: {})
        await server.configure(
            .init(
                isEnabled: true,
                port: 4627,
                hostname: "mac-imcp",
                funnelEnabled: true,
                cloudflareHostname: "imcp.example.com"
            )
        )

        try await waitUntil {
            if case .running(let endpoint) = states.last, case .failed = endpoint.funnel { return true }
            return false
        }
        XCTAssertEqual(local.shutdownCount, 0)
        let ok = await local.connect(sending: initializeRequest(secret: secret, host: "imcp.example.com"))
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"), ok)

        await server.stop()
        XCTAssertEqual(local.shutdownCount, 1)
    }

    private func makeStore() throws -> (AccessTokenStore, String) {
        let suite = "RemoteAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = InMemoryAccessTokenStorage()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AccessTokenStore(storage: storage, defaults: defaults)
        let (token, secret) = AccessToken.make(name: "iPad", permissions: .readOnly)
        try store.add(token)
        return (store, secret)
    }

    private func makeServer(
        store: AccessTokenStore,
        node: FakeTailnetNode,
        peerLifetime: TimeInterval = 60
    ) -> RemoteAccessServer {
        RemoteAccessServer(
            tokenStore: store,
            stateDirectory: URL(filePath: "/nonexistent/Tailscale"),
            makeNode: { _ in node },
            makeSessionServer: { _ in MCP.Server(name: "test", version: "1") },
            peerLifetime: peerLifetime
        )
    }

    private static func sessionID(in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "mcp-session-id" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func pingRequest(secret: String, sessionID: String) -> Data {
        let body = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        let head = [
            "POST /mcp HTTP/1.1",
            "Host: mac-imcp.example.ts.net:4627",
            "Authorization: Bearer \(secret)",
            "Accept: application/json, text/event-stream",
            "Content-Type: application/json",
            "MCP-Protocol-Version: 2025-11-25",
            "Mcp-Session-Id: \(sessionID)",
            "Content-Length: \(body.utf8.count)",
        ]
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    private func rawRequest(
        _ method: String,
        _ path: String,
        host: String,
        origin: String? = nil,
        body: String = ""
    ) -> Data {
        var head = ["\(method) \(path) HTTP/1.1", "Host: \(host)", "Content-Length: \(body.utf8.count)"]
        if method == "POST" { head.append("Content-Type: application/x-www-form-urlencoded") }
        if let origin { head.append("Origin: \(origin)") }
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
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

final class FunnelPolicyTests: XCTestCase {
    private func makeToken(bound: Bool = false) -> (AccessToken, String) {
        var (token, secret) = AccessToken.make(name: "Phone", permissions: .readOnly)
        if bound { token.boundDevice = .init(stableID: "nOwner", name: "iPad") }
        return (token, secret)
    }

    private func authorize(
        _ field: String?,
        tokens: [AccessToken],
        limiter: inout FailedAuthLimiter,
        now: Date = Date()
    ) -> FunnelPolicy.Decision {
        FunnelPolicy.authorize(
            authorizationField: field,
            lookup: { secret in tokens.first { $0.secretHash == AccessToken.hash(secret) } },
            limiter: &limiter,
            now: now
        )
    }

    func testAllowListAcceptsOnlyThePublicName() {
        let validator = FunnelPolicy.originValidator(host: "mac.tail1234.ts.net")
        func rejection(host: String, origin: String? = nil) -> Int? {
            var headers = ["Host": host]
            if let origin { headers["Origin"] = origin }
            let request = MCP.HTTPRequest(method: "POST", headers: headers, body: nil, path: "/mcp")
            let context = HTTPValidationContext(
                httpMethod: "POST",
                sessionID: nil,
                isInitializationRequest: false,
                supportedProtocolVersions: MCP.Version.supported
            )
            return validator.validate(request, context: context)?.statusCode
        }
        XCTAssertNil(rejection(host: "mac.tail1234.ts.net"))
        XCTAssertNil(rejection(host: "mac.tail1234.ts.net:443"))
        XCTAssertNil(rejection(host: "mac.tail1234.ts.net", origin: "https://mac.tail1234.ts.net"))
        XCTAssertNotNil(rejection(host: "mac.tail1234.ts.net:4627"))
        XCTAssertNotNil(rejection(host: "other.tail1234.ts.net"))
        XCTAssertNotNil(rejection(host: "127.0.0.1"))
        XCTAssertNotNil(rejection(host: "localhost:4627"))
        XCTAssertNotNil(rejection(host: "mac.tail1234.ts.net", origin: "http://mac.tail1234.ts.net"))
        XCTAssertNotNil(rejection(host: "mac.tail1234.ts.net", origin: "https://evil.example"))
    }

    func testNormalizesTheHostAndBuildsTheURL() {
        XCTAssertEqual(FunnelPolicy.normalizedHost("Mac.Tail1234.ts.net."), "mac.tail1234.ts.net")
        XCTAssertEqual(FunnelPolicy.publicURL(host: "mac.tail1234.ts.net"), "https://mac.tail1234.ts.net/mcp")
    }

    func testBearerTokenIsRequiredOnEveryRequest() {
        let (token, secret) = makeToken()
        var limiter = FailedAuthLimiter()
        XCTAssertEqual(authorize("Bearer \(secret)", tokens: [token], limiter: &limiter), .allowed(token))
        XCTAssertEqual(authorize("bearer \(secret)", tokens: [token], limiter: &limiter), .allowed(token))
        for field in [nil, "", "Bearer", "Basic \(secret)", "Bearer wrong", secret] {
            XCTAssertEqual(authorize(field, tokens: [token], limiter: &limiter), .unauthorized, field ?? "nil")
        }
    }

    func testTokensBoundToTailnetDevicesAreRejected() {
        let (token, secret) = makeToken(bound: true)
        var limiter = FailedAuthLimiter()
        XCTAssertEqual(authorize("Bearer \(secret)", tokens: [token], limiter: &limiter), .boundToDevice)
    }

    func testFailedAuthBlocksBadTokensForAWhile() {
        let (token, secret) = makeToken()
        var limiter = FailedAuthLimiter(maximumFailures: 3, window: 60, blockDuration: 120)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0 ..< 3 {
            XCTAssertEqual(authorize("Bearer x", tokens: [token], limiter: &limiter, now: start), .unauthorized)
        }
        XCTAssertEqual(
            authorize("Bearer x", tokens: [token], limiter: &limiter, now: start.addingTimeInterval(1)),
            .rateLimited(retryAfter: 119)
        )
        // The owner's token still works while others are blocked.
        XCTAssertEqual(
            authorize("Bearer \(secret)", tokens: [token], limiter: &limiter, now: start.addingTimeInterval(1)),
            .allowed(token)
        )
        // After the block, bad tokens count again.
        XCTAssertEqual(
            authorize("Bearer x", tokens: [token], limiter: &limiter, now: start.addingTimeInterval(121)),
            .unauthorized
        )
    }

    func testOldFailuresDoNotAddUp() {
        var limiter = FailedAuthLimiter(maximumFailures: 3, window: 60, blockDuration: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)
        limiter.recordFailure(now: start)
        limiter.recordFailure(now: start.addingTimeInterval(10))
        limiter.recordFailure(now: start.addingTimeInterval(100))
        XCTAssertNil(limiter.retryAfter(now: start.addingTimeInterval(100)))
    }

    func testPublicRequestLimitsAreSmallerThanTheTailnet() {
        let publicLimits = HTTPRequestParser.Limits.publicInternet
        let tailnet = HTTPRequestParser.Limits.tailnet
        XCTAssertLessThan(publicLimits.maximumBodyLength, tailnet.maximumBodyLength)
        XCTAssertLessThan(publicLimits.maximumHeaderLength, tailnet.maximumHeaderLength)

        let tooBig = Data(
            "POST /mcp HTTP/1.1\r\nContent-Length: \(publicLimits.maximumBodyLength + 1)\r\n\r\n".utf8
        )
        guard case .failure(let status, _) = HTTPRequestParser.parse(tooBig, limits: publicLimits) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertEqual(status, 413)
        // The tailnet's limit still takes the same body.
        XCTAssertEqual(HTTPRequestParser.parse(tooBig), .incomplete(expectsContinue: false))

        let manyFields =
            "GET / HTTP/1.1\r\n" + (0 ... publicLimits.maximumHeaderFields).map { "X-\($0): a\r\n" }.joined() + "\r\n"
        guard case .failure(let fieldStatus, _) = HTTPRequestParser.parse(Data(manyFields.utf8), limits: publicLimits)
        else { return XCTFail("Expected a failure") }
        XCTAssertEqual(fieldStatus, 431)
    }

    func testLoopbackListenerAcceptsAndExchangesBytes() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.shutdown() }
        XCTAssertNotEqual(listener.port, 0)

        let client = NWConnection(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: listener.port)),
            using: .tcp
        )
        client.start(queue: .global())
        defer { client.cancel() }
        client.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })

        let connection = try await listener.accept()
        XCTAssertNil(connection.remoteAddress)
        let received = try await connection.receive(timeout: .seconds(5))
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "ping")
        try await connection.send(Data("pong".utf8), timeout: .seconds(5))
        let reply: Data = await withCheckedContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                continuation.resume(returning: data ?? Data())
            }
        }
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "pong")

        await connection.close()
    }

    func testMultiHostAllowListAndMatchedHost() {
        let allowed: Set<String> = ["mac.tail1234.ts.net", "imcp.example.com"]
        let validator = FunnelPolicy.originValidator(hosts: allowed)
        func rejection(host: String, origin: String? = nil) -> Int? {
            var headers = ["Host": host]
            if let origin { headers["Origin"] = origin }
            let request = MCP.HTTPRequest(method: "POST", headers: headers, body: nil, path: "/mcp")
            let context = HTTPValidationContext(
                httpMethod: "POST",
                sessionID: nil,
                isInitializationRequest: false,
                supportedProtocolVersions: MCP.Version.supported
            )
            return validator.validate(request, context: context)?.statusCode
        }

        XCTAssertNil(rejection(host: "mac.tail1234.ts.net"))
        XCTAssertNil(rejection(host: "imcp.example.com"))
        XCTAssertNil(rejection(host: "imcp.example.com:443", origin: "https://imcp.example.com"))
        XCTAssertNil(rejection(host: "mac.tail1234.ts.net", origin: "https://mac.tail1234.ts.net"))
        XCTAssertNotNil(rejection(host: "imcp.example.com:4627"))
        XCTAssertNotNil(rejection(host: "imcp.example.com", origin: "http://imcp.example.com"))
        XCTAssertNotNil(rejection(host: "evil.example"))

        XCTAssertEqual(FunnelPolicy.matchedHost(in: "IMCP.EXAMPLE.COM.:443", allowedHosts: allowed), "imcp.example.com")
        XCTAssertEqual(FunnelPolicy.matchedHost(in: "IMCP.EXAMPLE.COM:443", allowedHosts: allowed), "imcp.example.com")
        XCTAssertEqual(FunnelPolicy.matchedHost(in: "imcp.example.com.", allowedHosts: allowed), "imcp.example.com")
        XCTAssertNil(FunnelPolicy.matchedHost(in: "imcp.example.com:4627", allowedHosts: allowed))
        XCTAssertNil(FunnelPolicy.matchedHost(in: "evil.example", allowedHosts: allowed))

        XCTAssertTrue(FunnelPolicy.isMissingFunnelACLError("node does not have the funnel capability"))
        XCTAssertFalse(FunnelPolicy.isMissingFunnelACLError("timed out"))
        XCTAssertTrue(FunnelPolicy.tailscaleNodeAttrsSnippet(ipv4Address: "100.64.1.2").contains("100.64.1.2"))
    }
}

final class CloudflareTunnelTests: XCTestCase {
    private static func makeCertPEM(accountID: String, zoneID: String?, apiToken: String) throws -> String {
        var object: [String: String] = [
            "accountID": accountID,
            "apiToken": apiToken,
        ]
        if let zoneID {
            object["zoneID"] = zoneID
        }
        let jsonData = try JSONSerialization.data(withJSONObject: object)
        let base64 = jsonData.base64EncodedString()
        return """
            -----BEGIN ARGO TUNNEL TOKEN-----
            \(base64)
            -----END ARGO TUNNEL TOKEN-----
            """
    }

    func testParsesCertPEM() throws {
        let pem = try Self.makeCertPEM(accountID: "acc_123", zoneID: "zone_456", apiToken: "tok_abc")
        let account = try CloudflareAccount.parseCertPEM(pem)
        XCTAssertEqual(account, CloudflareAccount(accountID: "acc_123", zoneID: "zone_456", apiToken: "tok_abc"))

        let noZone = try Self.makeCertPEM(accountID: "acc_123", zoneID: nil, apiToken: "tok_abc")
        let parsedNoZone = try CloudflareAccount.parseCertPEM(noZone)
        XCTAssertEqual(parsedNoZone, CloudflareAccount(accountID: "acc_123", zoneID: nil, apiToken: "tok_abc"))

        XCTAssertThrowsError(try CloudflareAccount.parseCertPEM("not valid base64!!!"))
    }

    func testDiscoverZonesFallsBackToSingleZoneOnListForbidden() async throws {
        let recorder = MockCloudflareTransport { request in
            let path = request.url?.path ?? ""
            if path == "/client/v4/zones" {
                return (
                    status: 403,
                    json: ["success": false, "errors": [["code": 10000, "message": "Authentication error"]]]
                )
            }
            if path == "/client/v4/zones/zone_only" {
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "zone_only",
                            "name": "example.com",
                            "status": "active",
                            "account": ["id": "acc_1", "name": "Oliver"],
                        ],
                    ]
                )
            }
            XCTFail("Unexpected path \(path)")
            return (status: 404, json: ["success": false])
        }

        let client = CloudflareAPIClient(apiToken: "tok_zone", transport: recorder.transport)
        let zones = try await client.discoverZones(preferredZoneID: "zone_only")
        XCTAssertEqual(zones.map(\.name), ["example.com"])
        XCTAssertEqual(zones.first?.account?.id, "acc_1")
    }

    func testProvisionTunnelCreatesTunnelIngressDNSAndFetchesToken() async throws {
        let recorder = MockCloudflareTransport { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            switch (method, path) {
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel"):
                return (status: 200, json: ["success": true, "result": []])
            case ("POST", "/client/v4/accounts/acc_1/cfd_tunnel"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "tun_123",
                            "name": "imcp-olivers-macbook-pro",
                            "status": "inactive",
                            "config_src": "cloudflare",
                        ],
                    ]
                )
            case ("PUT", "/client/v4/accounts/acc_1/cfd_tunnel/tun_123/configurations"):
                return (status: 200, json: ["success": true, "result": [:]])
            case ("GET", "/client/v4/zones/zone_1/dns_records"):
                return (status: 200, json: ["success": true, "result": []])
            case ("POST", "/client/v4/zones/zone_1/dns_records"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "dns_1",
                            "type": "CNAME",
                            "name": "imcp.example.com",
                            "content": "tun_123.cfargotunnel.com",
                            "proxied": true,
                        ],
                    ]
                )
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel/tun_123/token"):
                return (status: 200, json: ["success": true, "result": "run_token_secret"])
            default:
                XCTFail("Unexpected \(method) \(path)")
                return (status: 404, json: ["success": false])
            }
        }

        let client = CloudflareAPIClient(apiToken: "cf_secret", transport: recorder.transport)
        let result = try await client.provisionTunnel(
            accountID: "acc_1",
            zoneID: "zone_1",
            hostname: "imcp.example.com.",
            tunnelName: "imcp-olivers-macbook-pro",
            localPort: 54321
        )
        XCTAssertEqual(result.tunnelID, "tun_123")
        XCTAssertEqual(result.tunnelName, "imcp-olivers-macbook-pro")
        XCTAssertEqual(result.hostname, "imcp.example.com")
        XCTAssertEqual(result.runToken, "run_token_secret")

        let calls = recorder.calls
        XCTAssertEqual(
            calls.map { "\($0.method) \($0.path)" },
            [
                "GET /client/v4/accounts/acc_1/cfd_tunnel",
                "POST /client/v4/accounts/acc_1/cfd_tunnel",
                "PUT /client/v4/accounts/acc_1/cfd_tunnel/tun_123/configurations",
                "GET /client/v4/zones/zone_1/dns_records",
                "POST /client/v4/zones/zone_1/dns_records",
                "GET /client/v4/accounts/acc_1/cfd_tunnel/tun_123/token",
            ]
        )
        XCTAssertEqual(calls[1].jsonBody?["config_src"] as? String, "cloudflare")

        let config = try XCTUnwrap(calls[2].jsonBody?["config"] as? [String: Any])
        let ingress = try XCTUnwrap(config["ingress"] as? [[String: Any]])
        XCTAssertEqual(ingress.first?["hostname"] as? String, "imcp.example.com")
        XCTAssertEqual(ingress.first?["service"] as? String, "http://127.0.0.1:54321")
        XCTAssertEqual(ingress.last?["service"] as? String, "http_status:404")

        XCTAssertEqual(calls[4].jsonBody?["type"] as? String, "CNAME")
        XCTAssertEqual(calls[4].jsonBody?["content"] as? String, "tun_123.cfargotunnel.com")
        XCTAssertEqual(calls[4].jsonBody?["proxied"] as? Bool, true)
    }

    func testProvisionTunnelAdoptsExistingTunnelAndUpdatesOutdatedCNAME() async throws {
        let recorder = MockCloudflareTransport { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            switch (method, path) {
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            [
                                "id": "tun_existing",
                                "name": "imcp-mac",
                                "status": "healthy",
                                "config_src": "cloudflare",
                            ]
                        ],
                    ]
                )
            case ("PUT", "/client/v4/accounts/acc_1/cfd_tunnel/tun_existing/configurations"):
                return (status: 200, json: ["success": true, "result": [:]])
            case ("GET", "/client/v4/zones/zone_1/dns_records"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            [
                                "id": "rec_old",
                                "type": "CNAME",
                                "name": "imcp.example.net",
                                "content": "old.cfargotunnel.com",
                                "proxied": false,
                            ]
                        ],
                    ]
                )
            case ("PUT", "/client/v4/zones/zone_1/dns_records/rec_old"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "rec_old",
                            "type": "CNAME",
                            "name": "imcp.example.net",
                            "content": "tun_existing.cfargotunnel.com",
                            "proxied": true,
                        ],
                    ]
                )
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel/tun_existing/token"):
                return (status: 200, json: ["success": true, "result": "adopted_token"])
            default:
                XCTFail("Unexpected \(method) \(path)")
                return (status: 404, json: ["success": false])
            }
        }

        let client = CloudflareAPIClient(apiToken: "cf_secret", transport: recorder.transport)
        let result = try await client.provisionTunnel(
            accountID: "acc_1",
            zoneID: "zone_1",
            hostname: "imcp.example.net",
            tunnelName: "imcp-mac",
            localPort: 60000
        )
        XCTAssertEqual(result.tunnelID, "tun_existing")
        XCTAssertEqual(result.runToken, "adopted_token")
        XCTAssertFalse(recorder.calls.contains { $0.method == "POST" })
        XCTAssertTrue(recorder.calls.contains { $0.method == "PUT" && $0.path.hasSuffix("/dns_records/rec_old") })
    }

    @MainActor
    func testControllerLoginProvisionConnectAndDisconnect() async throws {
        let suite = "CloudflareTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let recorder = MockCloudflareTransport { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            switch (method, path) {
            case ("GET", "/client/v4/zones"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            [
                                "id": "zone_1",
                                "name": "example.com",
                                "status": "active",
                                "account": ["id": "acc_1", "name": "Ames"],
                            ],
                            [
                                "id": "zone_2",
                                "name": "example.net",
                                "status": "active",
                                "account": ["id": "acc_1", "name": "Ames"],
                            ],
                        ],
                    ]
                )
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel"):
                return (status: 200, json: ["success": true, "result": []])
            case ("POST", "/client/v4/accounts/acc_1/cfd_tunnel"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "tun_mac",
                            "name": "imcp-test-mac",
                            "status": "inactive",
                            "config_src": "cloudflare",
                        ],
                    ]
                )
            case ("PUT", "/client/v4/accounts/acc_1/cfd_tunnel/tun_mac/configurations"):
                return (status: 200, json: ["success": true, "result": [:]])
            case ("GET", "/client/v4/zones/zone_2/dns_records"):
                return (status: 200, json: ["success": true, "result": []])
            case ("POST", "/client/v4/zones/zone_2/dns_records"):
                return (
                    status: 200,
                    json: [
                        "success": true,
                        "result": [
                            "id": "rec_2",
                            "type": "CNAME",
                            "name": "imcp.example.net",
                            "content": "tun_mac.cfargotunnel.com",
                            "proxied": true,
                        ],
                    ]
                )
            case ("GET", "/client/v4/accounts/acc_1/cfd_tunnel/tun_mac/token"):
                return (status: 200, json: ["success": true, "result": "cf_run_token"])
            default:
                XCTFail("Unexpected \(method) \(path)")
                return (status: 404, json: ["success": false])
            }
        }

        let runner = FakeCloudflareProcessRunner()
        let secrets = InMemoryCloudflareSecretStorage()
        let controller = CloudflareTunnelController(
            secretStorage: secrets,
            defaults: defaults,
            httpTransport: recorder.transport,
            processRunner: runner,
            containerCertURL: URL(fileURLWithPath: "/nonexistent/cert.pem"),
            certSearchURLs: [],
            computerName: "Test Mac"
        )
        XCTAssertEqual(controller.defaultTunnelName, "imcp-test-mac")
        XCTAssertEqual(controller.state, .off)

        let requestedHost = LockedBox<String?>(nil)
        controller.onActiveHostnameChanged = { requestedHost.value = $0 }

        await controller.logIn(credentialInput: "api_token_123")
        XCTAssertEqual(controller.zones.map(\.name), ["example.com", "example.net"])
        XCTAssertEqual(controller.hostnameDraft, "imcp.example.com")

        // Switching the zone updates the suggested hostname prefix cleanly.
        controller.selectedZoneID = "zone_2"
        XCTAssertEqual(controller.hostnameDraft, "imcp.example.net")

        await controller.provisionAndConnect()
        XCTAssertEqual(requestedHost.value, "imcp.example.net")

        // Simulate RemoteAccessServer starting LoopbackListener on port 55123.
        controller.handleLoopbackPortChange(55123)
        try await waitUntil {
            if case .connected = await controller.state { return true }
            return false
        }

        XCTAssertEqual(
            controller.state,
            .connected(
                url: "https://imcp.example.net/mcp",
                tunnelName: "imcp-test-mac",
                tunnelID: "tun_mac"
            )
        )
        XCTAssertEqual(runner.startedTokens, ["cf_run_token"])

        controller.disconnect()
        XCTAssertNil(requestedHost.value)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(runner.terminatedCount, 1)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class MockCloudflareTransport: @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let query: String?
        let bodyData: Data?

        var jsonBody: [String: Any]? {
            guard let bodyData else { return nil }
            return try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let handler: @Sendable (URLRequest) throws -> (status: Int, json: Any)

    init(handler: @escaping @Sendable (URLRequest) throws -> (status: Int, json: Any)) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { _calls } }

    var transport: CloudflareAPIClient.HTTPTransport {
        { [self] request in
            let call = Call(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                query: request.url?.query,
                bodyData: request.httpBody
            )
            lock.withLock { _calls.append(call) }
            let (status, json) = try handler(request)
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url ?? CloudflareAPIClient.baseURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
    }
}

private final class FakeCloudflareProcessRunner: CloudflareProcessRunner, @unchecked Sendable {
    private final class Handle: CloudflareProcessHandle, @unchecked Sendable {
        let onTerminate: @Sendable () -> Void
        init(onTerminate: @escaping @Sendable () -> Void) { self.onTerminate = onTerminate }
        func terminate() { onTerminate() }
    }

    private let lock = NSLock()
    private var _startedTokens: [String] = []
    private var _terminatedCount = 0
    var browserAccount: CloudflareAccount?

    var startedTokens: [String] { lock.withLock { _startedTokens } }
    var terminatedCount: Int { lock.withLock { _terminatedCount } }

    func findBinary() -> URL? {
        URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared")
    }

    func runBrowserLogin(origincertURL: URL) async throws -> CloudflareAccount {
        if let browserAccount { return browserAccount }
        throw CloudflareError.loginFailed("cancelled")
    }

    func startTunnel(
        runToken: String,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws -> any CloudflareProcessHandle {
        lock.withLock { _startedTokens.append(runToken) }
        return Handle { [self] in
            lock.withLock { _terminatedCount += 1 }
        }
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
    private var peers: [String: TailnetPeer]
    private var listeners: [FakeTailnetListener] = []
    private var _listenedAddresses: [String] = []
    private var _logoutCount = 0
    private var _closeCount = 0
    private var _funnelPorts: [UInt16] = []
    private var _disableFunnelCount = 0
    /// The error that `enableFunnel` throws, such as when the tailnet's policy doesn't allow Funnel.
    var funnelError: Error?

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
    var funnelPorts: [UInt16] { lock.withLock { _funnelPorts } }
    var disableFunnelCount: Int { lock.withLock { _disableFunnelCount } }

    private var holdEnable = false
    private var enableWaiters: [CheckedContinuation<Void, Never>] = []
    private var _funnelEvents: [String] = []
    var funnelEvents: [String] { lock.withLock { _funnelEvents } }

    /// Makes `enableFunnel` wait until `releaseFunnelEnable()`.
    func holdFunnelEnable() { lock.withLock { holdEnable = true } }

    func releaseFunnelEnable() {
        let waiters = lock.withLock {
            holdEnable = false
            defer { enableWaiters.removeAll() }
            return enableWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func enableFunnel(localPort: UInt16) async throws -> String {
        lock.withLock { _funnelEvents.append("enable-started") }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hold = lock.withLock {
                if holdEnable { enableWaiters.append(continuation) }
                return holdEnable
            }
            if !hold { continuation.resume() }
        }
        if let funnelError { throw funnelError }
        lock.withLock {
            _funnelPorts.append(localPort)
            _funnelEvents.append("enable-finished")
        }
        return "Mac-iMCP.example.ts.net."
    }

    func disableFunnel() async throws {
        lock.withLock {
            _disableFunnelCount += 1
            _funnelEvents.append("disable")
        }
    }

    func status() async throws -> TailnetStatus {
        TailnetStatus(state: state)
    }

    func whois(_ address: String) async throws -> TailnetPeer {
        guard let peer = lock.withLock({ peers[address] }) else { throw URLError(.cannotFindHost) }
        return peer
    }

    /// Changes the device at an address, such as when its owner or tags change.
    func setPeer(_ peer: TailnetPeer?, at address: String) {
        lock.withLock { peers[address] = peer }
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

    /// Opens a connection that stays open for more requests.
    func open(from address: String) throws -> OpenTailnetConnection {
        let listener = try XCTUnwrap(lock.withLock { listeners.last })
        let connection = OpenTailnetConnection(remoteAddress: address)
        listener.yield(connection)
        return connection
    }
}

/// A connection whose peer sends one byte every 50 ms and never finishes a request.
private final class TrickleConnection: TailnetConnection, @unchecked Sendable {
    let remoteAddress: String? = nil
    private let lock = NSLock()
    private var _isClosed = false
    var isClosed: Bool { lock.withLock { _isClosed } }

    func receive(timeout: Duration) async throws -> Data {
        let delay = Duration.milliseconds(50)
        if timeout < delay {
            try await Task.sleep(for: timeout)
            throw POSIXError(.ETIMEDOUT)
        }
        try await Task.sleep(for: delay)
        return Data("x".utf8)
    }

    func send(_ data: Data, timeout: Duration) async throws {}

    func close() async { lock.withLock { _isClosed = true } }
}

/// A connection whose peer sends requests when the test asks it to.
private final class OpenTailnetConnection: TailnetConnection, @unchecked Sendable {
    let remoteAddress: String?
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var iterator: AsyncStream<Data>.AsyncIterator?
    private var sent = Data()
    private var _isClosed = false

    init(remoteAddress: String) {
        self.remoteAddress = remoteAddress
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    var output: String { lock.withLock { String(decoding: sent, as: UTF8.self) } }
    var isClosed: Bool { lock.withLock { _isClosed } }

    func write(_ request: Data) { continuation.yield(request) }

    func receive(timeout: Duration) async throws -> Data {
        // Only the server's connection task calls this, one call at a time.
        var iterator = lock.withLock { self.iterator }
        let next = await iterator?.next()
        lock.withLock { self.iterator = iterator }
        return next ?? Data()
    }

    func send(_ data: Data, timeout: Duration) async throws {
        try lock.withLock {
            guard !_isClosed else { throw CancellationError() }
            sent.append(data)
        }
    }

    func close() async {
        lock.withLock { _isClosed = true }
        continuation.finish()
    }
}

/// A listener on a pretend 127.0.0.1 port, where Funnel forwards public connections.
private final class FakeLocalListener: LocalForwardListener, @unchecked Sendable {
    let port: UInt16 = 54321
    private let inner = FakeTailnetListener()
    private let lock = NSLock()
    private var _shutdownCount = 0

    var shutdownCount: Int { lock.withLock { _shutdownCount } }

    func accept() async throws -> any TailnetConnection { try await inner.accept() }

    func shutdown() {
        lock.withLock { _shutdownCount += 1 }
        inner.finish()
    }

    /// Sends the bytes as a forwarded connection, which has no address,
    /// and returns what the server sends before it closes the connection.
    func connect(sending request: Data) async -> String {
        let connection = FakeTailnetConnection(remoteAddress: nil, request: request)
        inner.yield(connection)
        return String(decoding: await connection.output(), as: UTF8.self)
    }
}

private final class FakeTailnetListener: TailnetListener, @unchecked Sendable {
    private let stream: AsyncStream<any TailnetConnection>
    private let continuation: AsyncStream<any TailnetConnection>.Continuation
    private let lock = NSLock()
    private var iterator: AsyncStream<any TailnetConnection>.AsyncIterator?

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func yield(_ connection: any TailnetConnection) { continuation.yield(connection) }
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

    init(remoteAddress: String?, request: Data) {
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
