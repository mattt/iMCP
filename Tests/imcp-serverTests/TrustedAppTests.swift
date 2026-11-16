import Foundation
import MCP
import XCTest

/// Tests for trust by code signature, the terminal exclusion, and the Claude Code settings write.
///
/// They check real system apps' signatures, so they need no signed build of iMCP.
@MainActor
final class TrustedAppTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: InMemoryClientRecordStorage!

    private let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    private let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
    private let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    override func setUp() async throws {
        suiteName = "imcp-trusted-app-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = InMemoryClientRecordStorage()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ClientCredentialStore {
        ClientCredentialStore(storage: storage, defaults: defaults)
    }

    private func app(at url: URL) throws -> ResponsibleApp {
        try XCTUnwrap(ResponsibleApp.read(appAt: url), url.lastPathComponent)
    }

    // MARK: - Requirement matching

    func testTrustedAppConnectsWithoutDialogAndOtherAppsStillAsk() throws {
        let store = makeStore()
        let calculator = try app(at: calculatorURL)
        XCTAssertTrue(calculator.isTrustableBySignature)

        guard case .ask = store.evaluate(credential: nil, claimedName: "calc", app: calculator) else {
            return XCTFail("An app that isn't trusted yet should ask")
        }
        let record = try store.trustApp(calculator)
        XCTAssertTrue(record.isApp)

        guard case .approve(let approved) = store.evaluate(credential: nil, claimedName: "anything", app: calculator)
        else { return XCTFail("The trusted app should connect without a dialog") }
        XCTAssertEqual(approved.id, record.id)

        guard case .ask = store.evaluate(credential: nil, claimedName: "calc", app: try app(at: calendarURL)) else {
            return XCTFail("Another app must not satisfy Calculator's requirement")
        }
        guard case .ask = store.evaluate(credential: nil, claimedName: "calc", app: nil) else {
            return XCTFail("A connection with no identified app must not match")
        }
    }

    func testRevokingAppTrustMakesItAskAgain() throws {
        let store = makeStore()
        let calculator = try app(at: calculatorURL)
        let record = try store.trustApp(calculator)
        try store.revoke(id: record.id)
        guard case .ask = store.evaluate(credential: nil, claimedName: "calc", app: calculator) else {
            return XCTFail("A revoked app should ask")
        }
    }

    func testStoredRequirementMustBeSatisfiedNotJustNamed() throws {
        let store = makeStore()
        let calculator = try app(at: calculatorURL)
        // A record whose requirement names Calendar must not approve Calculator.
        let calendar = try app(at: calendarURL)
        try storage.save(
            ClientRecord(
                id: "x",
                name: "Calendar",
                issuedAt: .now,
                isTrusted: true,
                requirement: try XCTUnwrap(calendar.requirement)
            )
        )
        store.reload()
        guard case .ask = store.evaluate(credential: nil, claimedName: "calc", app: calculator) else {
            return XCTFail("Calendar's requirement must not approve Calculator")
        }
        guard case .approve = store.evaluate(credential: nil, claimedName: "cal", app: calendar) else {
            return XCTFail("Calendar's requirement should approve Calendar")
        }
    }

    // MARK: - Terminals and generic runtimes

    func testTerminalIsNotTrustableBySignature() throws {
        let terminal = try app(at: terminalURL)
        XCTAssertNotNil(terminal.requirement)
        XCTAssertFalse(terminal.isTrustableBySignature)

        let store = makeStore()
        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "some-cli", app: terminal) else {
            return XCTFail("A terminal should ask")
        }
        XCTAssertEqual(request.offer, .copiedCredential)
        XCTAssertNil(request.signatureKey)
    }

    func testUnsignedAdHocAndNonBundleAppsAreNotTrustable() {
        func candidate(adHoc: Bool = false, team: String? = "TEAMID1234", path: String? = "/Applications/X.app")
            -> ResponsibleApp
        {
            ResponsibleApp(
                name: "X",
                bundleIdentifier: "com.example.x",
                bundlePath: path,
                teamIdentifier: team,
                teamName: nil,
                requirement: "identifier \"com.example.x\"",
                isAppleSigned: false,
                isAdHocSigned: adHoc,
                code: nil
            )
        }
        XCTAssertTrue(candidate().isTrustableBySignature)
        XCTAssertFalse(candidate(adHoc: true).isTrustableBySignature)
        XCTAssertFalse(candidate(team: nil).isTrustableBySignature)
        XCTAssertFalse(candidate(path: nil).isTrustableBySignature, "A bare executable such as node")
    }

    func testClaudeCodeGetsSetUpEvenInATrustedApp() throws {
        let store = makeStore()
        let calculator = try app(at: calculatorURL)
        try store.trustApp(calculator)

        // Claude Code can run inside a trusted editor's terminal.
        // The editor's trust must not approve it, and it's offered setup, not signature trust.
        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "claude-code", app: calculator)
        else { return XCTFail("A client claiming to be Claude Code should ask") }
        XCTAssertEqual(request.offer, .claudeCodeSetup)
    }

    // MARK: - Claude Code settings

    func testUpsertKeepsOtherSettingsAndReplacesTheIMCPEntry() throws {
        let original = Data(
            """
            {"numStartups": 7, "mcpServers": {"other": {"command": "x"}, "iMCP": {"command": "old"}}}
            """.utf8
        )
        let updated = try MCPClientConfig.upserting(
            server: "iMCP",
            entry: ["command": "new", "env": .object(["IMCP_CLIENT_CREDENTIAL": "imcp_abc"])],
            into: original
        )
        let config = try JSONDecoder().decode([String: Value].self, from: updated)
        XCTAssertEqual(config["numStartups"]?.intValue, 7)
        let servers = try XCTUnwrap(config["mcpServers"]?.objectValue)
        XCTAssertEqual(servers["other"]?.objectValue?["command"]?.stringValue, "x")
        XCTAssertEqual(servers["iMCP"]?.objectValue?["command"]?.stringValue, "new")
        XCTAssertEqual(
            MCPClientConfig.environmentValue("IMCP_CLIENT_CREDENTIAL", server: "iMCP", in: updated),
            "imcp_abc"
        )

        let fresh = try MCPClientConfig.upserting(server: "iMCP", entry: ["command": "new"], into: nil)
        XCTAssertNotNil(try JSONDecoder().decode([String: Value].self, from: fresh)["mcpServers"])
    }

    func testAtomicWriteKeepsPermissionsAndLeavesNoTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(".claude.json")
        try MCPClientConfig.writeAtomically(Data("{}".utf8), to: url)
        XCTAssertEqual(try permissions(of: url), 0o600, "A new file is private")

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try MCPClientConfig.writeAtomically(Data("{\"a\":1}".utf8), to: url)
        XCTAssertEqual(try permissions(of: url), 0o640, "An existing file keeps its permissions")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [".claude.json"])
    }

    private func permissions(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
