import AppKit
import MCP
import Network
import XCTest

final class HomeProxyTests: XCTestCase {
    @MainActor
    func testLiveLaunchAndRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMCP_HELPER_PATH"] else {
            throw XCTSkip("Set IMCP_HELPER_PATH to run the signed helper integration test.")
        }
        let backend = HomeService(helperURL: URL(fileURLWithPath: path))
        let initial = await backend.isActivated
        XCTAssertFalse(initial)
        try await backend.activate()
        let active = await backend.isActivated
        XCTAssertTrue(active)
        let homes = try await backend.call("homes_list", [:])
        XCTAssertNotEqual(homes, .null)
        do {
            _ = try await backend.call("accessories_get", ["accessory": "invalid"])
            XCTFail("The helper must report invalid accessory IDs.")
        } catch let error as HomeError {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        // Terminate only the helper this test launched, not another helper build.
        let helper = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
            }
        )
        XCTAssertTrue(helper.forceTerminate())
        for _ in 0 ..< 50 {
            if helper.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(helper.isTerminated)
        let recovered = try await backend.call("homes_list", [:])
        XCTAssertEqual(recovered, homes)
        let reactivated = await backend.isActivated
        XCTAssertTrue(reactivated)
    }
}

final class HomeHelperSecretTests: XCTestCase {
    func testGeneratesDistinctSecretsOf32Bytes() throws {
        let first = try HomeHelperSecret.generate()
        let second = try HomeHelperSecret.generate()
        XCTAssertEqual(Data(base64Encoded: first)?.count, 32)
        XCTAssertNotEqual(first, second)
    }

    func testMatchesOnlyTheSameSecret() throws {
        let secret = try HomeHelperSecret.generate()
        XCTAssertTrue(HomeHelperSecret.matches(secret, secret))
        XCTAssertFalse(HomeHelperSecret.matches(nil, secret))
        XCTAssertFalse(HomeHelperSecret.matches("", secret))
        XCTAssertFalse(HomeHelperSecret.matches(String(secret.dropLast()), secret))
        XCTAssertFalse(HomeHelperSecret.matches(secret + "A", secret))
        XCTAssertFalse(HomeHelperSecret.matches(try HomeHelperSecret.generate(), secret))
        XCTAssertFalse(HomeHelperSecret.matches("", ""))
    }

    func testHelperServesOnlyClientsWithTheSecret() async throws {
        let secret = try HomeHelperSecret.generate()
        let (server, port) = try await startServer(secret: secret)

        // Strict mode drops requests before initialize,
        // and the helper ends a connection that doesn't present the secret.
        let early = try await exchange(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, port: port)
        XCTAssertNil(early)

        // A wrong or missing secret ends the connection without a reply.
        for capabilities in [#"{"experimental":{"app.imcp.helper.secret":"wrong"}}"#, "{}"] {
            let reply = try await exchange(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","#
                    + #""clientInfo":{"name":"iMCP","version":"1"},"capabilities":"# + capabilities + "}}",
                port: port
            )
            XCTAssertNil(reply, capabilities)
        }

        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let client = MCP.Client(
            name: "iMCP",
            version: "1",
            capabilities: .init(experimental: [HomeHelperSecret.capabilityKey: secret])
        )
        let result = try await client.connect(
            transport: NetworkTransport(
                connection: connection,
                heartbeatConfig: .init(enabled: false),
                reconnectionConfig: .disabled
            )
        )
        XCTAssertEqual(result.serverInfo.name, "iMCP Helper")
        let tools = try await client.listTools().tools
        XCTAssertEqual(tools.count, 28)
        let call = try await client.callTool(name: "homes_list")
        XCTAssertEqual(call.isError, false)
        await client.disconnect()
        withExtendedLifetime(server) {}
    }

    /// Starts a helper server on a free loopback port.
    /// Another socket can take the selected port before the listener binds it,
    /// so this selects a new port if that happens.
    private func startServer(secret: String) async throws -> (HelperServer, UInt16) {
        for attempt in 1 ... 3 {
            let port = try HomeService().availableLoopbackPort()
            let server = HelperServer(
                backend: StaticHomeBackend(),
                port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
                secret: secret
            )
            do {
                try await server.start()
                return (server, port)
            } catch {
                if attempt == 3 { throw error }
            }
        }
        throw HomeError("No free loopback port for the helper server.")
    }

    /// Sends one JSON-RPC message and returns the first line of the reply,
    /// or nil if the helper closes the connection first.
    private func exchange(_ message: String, port: UInt16) async throws -> String? {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .main)
        connection.send(content: Data((message + "\n").utf8), completion: .idempotent)
        let start = ContinuousClock.now
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            connection.cancel()
        }
        defer { timeout.cancel() }
        var received = Data()
        while true {
            let (data, closed) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data { received.append(data) }
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: received[..<newline], as: UTF8.self)
            }
            if closed {
                if ContinuousClock.now - start >= .seconds(10) {
                    throw HomeError("The helper neither replied to nor closed \(message)")
                }
                return received.isEmpty ? nil : String(decoding: received, as: UTF8.self)
            }
        }
    }
}

private struct StaticHomeBackend: HomeBackend {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value { .object(["homes": .array([])]) }
}

final class HomeHelperLocatorTests: XCTestCase {
    private let chosen = URL(fileURLWithPath: "/Users/x/Build/iMCP Helper.app")
    private let system = URL(fileURLWithPath: "/Applications/iMCP Helper.app")
    private let user = URL(fileURLWithPath: "/Users/x/Applications/iMCP Helper.app")
    private let registered = URL(fileURLWithPath: "/Users/x/Dev/iMCP Helper.app")
    private let embedded = URL(fileURLWithPath: "/Applications/iMCP.app/Contents/Helpers/iMCP Helper.app")

    func testChosenHelperWins() {
        let url = HomeHelperLocator.resolve(
            chosen: chosen,
            installed: [system, user],
            registered: registered,
            embedded: embedded,
            isHelper: { _ in true }
        )
        XCTAssertEqual(url, chosen)
    }

    func testFallsBackInOrderWhenChosenIsGone() {
        let url = HomeHelperLocator.resolve(
            chosen: chosen,
            installed: [system, user],
            registered: registered,
            embedded: embedded,
            isHelper: { $0 != self.chosen && $0 != self.system }
        )
        XCTAssertEqual(url, user)
    }

    func testRegisteredThenEmbedded() {
        XCTAssertEqual(
            HomeHelperLocator.resolve(
                chosen: nil,
                installed: [system, user],
                registered: registered,
                embedded: embedded,
                isHelper: { $0 == self.registered || $0 == self.embedded }
            ),
            registered
        )
        XCTAssertEqual(
            HomeHelperLocator.resolve(
                chosen: nil,
                installed: [system, user],
                registered: nil,
                embedded: embedded,
                isHelper: { $0 == self.embedded }
            ),
            embedded
        )
    }

    func testRejectsAppsWithoutTheMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func app(_ name: String, marker: Bool?) throws -> URL {
            let url = directory.appendingPathComponent("\(name).app")
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "test.\(name)", "CFBundlePackageType": "APPL"]
            if let marker { info[HomeHelperLocator.markerKey] = marker }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        XCTAssertTrue(HomeHelperLocator.isHelper(at: try app("Helper", marker: true)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: try app("Other", marker: nil)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: try app("Off", marker: false)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: directory.appendingPathComponent("Missing.app")))
        XCTAssertNil(
            HomeHelperLocator.resolve(
                chosen: try app("Chosen", marker: nil),
                installed: [],
                registered: nil,
                embedded: nil,
                isHelper: HomeHelperLocator.isHelper(at:)
            )
        )
    }

    func testInstallLocations() {
        // The sandbox can't read ~/Applications without a user selection,
        // so only /Applications is searched automatically.
        XCTAssertEqual(
            HomeHelperLocator.installLocations.map(\.path),
            ["/Applications/iMCP Helper.app"]
        )
    }

    func testRunningHelperMatchesTheResolvedPathWithoutReadingInfoPlist() {
        var reads = 0
        let isHelper: (URL) -> Bool = { _ in
            reads += 1
            return false
        }
        XCTAssertTrue(
            HomeHelperLocator.isRunningHelper(
                bundleURL: URL(fileURLWithPath: "/Users/x/Build/./iMCP Helper.app"),
                localizedName: "iMCP Helper",
                helper: chosen,
                isHelper: isHelper
            )
        )
        XCTAssertEqual(reads, 0)
    }

    func testRunningHelperMustMatchTheResolvedPathWhenOneIsKnown() {
        // A differently located helper, such as an older build,
        // must not stand in for the helper the user chose.
        XCTAssertFalse(
            HomeHelperLocator.isRunningHelper(
                bundleURL: registered,
                localizedName: "iMCP Helper",
                helper: chosen,
                isHelper: { _ in true }
            )
        )
    }

    func testRunningHelperChecksTheMarkerOnlyForAppsNamediMCPHelper() {
        var reads = 0
        let isHelper: (URL) -> Bool = { _ in
            reads += 1
            return true
        }
        XCTAssertFalse(
            HomeHelperLocator.isRunningHelper(
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                localizedName: "Safari",
                helper: system,
                isHelper: isHelper
            )
        )
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(
            HomeHelperLocator.isRunningHelper(
                bundleURL: registered,
                localizedName: "iMCP Helper",
                helper: nil,
                isHelper: isHelper
            )
        )
        XCTAssertFalse(
            HomeHelperLocator.isRunningHelper(
                bundleURL: nil,
                localizedName: "iMCP Helper",
                helper: system,
                isHelper: isHelper
            )
        )
    }
}
