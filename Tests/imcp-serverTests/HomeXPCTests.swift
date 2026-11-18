import MCP
import Security
import ServiceManagement
import XCTest

final class HomeXPCProtocolTests: XCTestCase {
    func testRequestResponseAndStatusSurviveAJSONRoundTrip() throws {
        let request = HomeXPCRequest(
            tool: "characteristics_write",
            arguments: ["characteristic": "id", "value": 0.5, "nested": ["flag": true, "list": [1, "two", .null]]]
        )
        XCTAssertEqual(try JSONDecoder().decode(HomeXPCRequest.self, from: JSONEncoder().encode(request)), request)
        for response in [HomeXPCResponse.success(#"{"ok":true}"#), .failure("No such home.")] {
            XCTAssertEqual(
                try JSONDecoder().decode(HomeXPCResponse.self, from: JSONEncoder().encode(response)),
                response
            )
        }
        let status = HomeXPCStatus(protocolVersion: 4, homeKitReady: false, detail: "Waiting for HomeKit access.")
        XCTAssertEqual(try JSONDecoder().decode(HomeXPCStatus.self, from: JSONEncoder().encode(status)), status)
    }

    func testTheXPCInterfaceCarriesOnlyDataAndClosures() {
        // NSXPCInterface raises if a method uses a type XPC can't carry.
        _ = NSXPCInterface(with: HomeHelperXPC.self)
    }

    func testDispatcherRunsAKnownToolAndReturnsItsJSON() async throws {
        let recorder = RecordingBackend()
        let request = try JSONEncoder().encode(HomeXPCRequest(tool: "rooms_list", arguments: ["home": "H1"]))
        let response = await HomeToolDispatcher(backend: recorder).perform(request)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result, #"{"home":"H1"}"#)
        let calls = await recorder.calls
        XCTAssertEqual(calls, ["rooms_list"])
    }

    func testDispatcherRefusesUnknownToolsBadArgumentsAndBadJSON() async throws {
        let recorder = RecordingBackend()
        let dispatcher = HomeToolDispatcher(backend: recorder)
        let unknown = try JSONEncoder().encode(HomeXPCRequest(tool: "shell_exec", arguments: [:]))
        let unknownResponse = await dispatcher.perform(unknown)
        XCTAssertEqual(unknownResponse.error, "Unknown Home tool: shell_exec")
        let invalid = try JSONEncoder().encode(
            HomeXPCRequest(tool: "rooms_create", arguments: ["name": "Test", "surprise": true])
        )
        let invalidResponse = await dispatcher.perform(invalid)
        XCTAssertNotNil(invalidResponse.error)
        let garbage = await dispatcher.perform(Data("not json".utf8))
        XCTAssertNotNil(garbage.error)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [], "A refused request must not reach HomeKit.")
    }

    func testDispatcherReportsAToolFailureAsAnErrorResponse() async throws {
        let request = try JSONEncoder().encode(HomeXPCRequest(tool: "homes_list", arguments: [:]))
        let response = await HomeToolDispatcher(backend: FailingBackend()).perform(request)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "HomeKit refused.")
    }
}

final class HomeHelperIdentityTests: XCTestCase {
    func testNamesDeriveFromTheAppBundleIdentifier() {
        for app in ["com.example.imcp", "co.dododo.iMCP"] {
            XCTAssertEqual(HomeHelperIdentity.machServiceName(appBundleIdentifier: app), app + ".home-xpc")
            XCTAssertEqual(HomeHelperIdentity.agentLabel(appBundleIdentifier: app), app + ".home-helper")
            XCTAssertEqual(HomeHelperIdentity.agentPlistName(appBundleIdentifier: app), app + ".home-helper.plist")
        }
    }

    func testTheHelperFindsTheAppThatItsOwnIdentifierNames() {
        XCTAssertEqual(
            HomeHelperIdentity.appBundleIdentifier(helperBundleIdentifier: "co.dododo.iMCP.Helper"),
            "co.dododo.iMCP"
        )
        XCTAssertEqual(
            HomeHelperIdentity.appBundleIdentifier(helperBundleIdentifier: "com.example.imcp.Helper"),
            "com.example.imcp"
        )
        for other in [nil, "", "helper", ".helper", "com.example.NotAHelperSuffix"] {
            XCTAssertEqual(
                HomeHelperIdentity.appBundleIdentifier(helperBundleIdentifier: other),
                HomeHelperIdentity.defaultAppBundleIdentifier,
                other ?? "nil"
            )
        }
    }

    func testRequirementsNameTheIdentifierAndTeamExactly() throws {
        XCTAssertEqual(
            HomeHelperIdentity.helperRequirement(
                helperBundleIdentifier: "com.example.imcp.Helper",
                team: "ABCDE12345"
            ),
            #"anchor apple generic and identifier "com.example.imcp.Helper" and certificate leaf[subject.OU] = "ABCDE12345""#
        )
        // The helper requires the app that its own identifier names, with the helper's own team.
        XCTAssertEqual(
            HomeHelperIdentity.clientRequirement(
                helperBundleIdentifier: "co.dododo.iMCP.Helper",
                team: "ABCDE12345"
            ),
            #"anchor apple generic and identifier "co.dododo.iMCP" and certificate leaf[subject.OU] = "ABCDE12345""#
        )
    }

    func testRequirementsRefuseValuesThatCouldLoosenThem() {
        let team = "ABCDE12345"
        for identifier in [#"x" or anchor apple"#, "a b", "", "a\"", "app) or (identifier \"b"] {
            XCTAssertNil(HomeHelperIdentity.requirement(identifier: identifier, team: team), identifier)
        }
        for badTeam in ["", "abcde12345", "ABCDE1234", "ABCDE12345G", #"ABCDE12345" or "#, "ABCDE1 345"] {
            XCTAssertNil(HomeHelperIdentity.requirement(identifier: "com.example.app", team: badTeam), badTeam)
        }
    }

    func testTheRequirementsCompileAsRealCodeRequirements() throws {
        for requirement in [
            HomeHelperIdentity.helperRequirement(helperBundleIdentifier: "com.example.imcp.helper", team: "ABCDE12345"),
            HomeHelperIdentity.clientRequirement(helperBundleIdentifier: "com.example.imcp.helper", team: "ABCDE12345"),
        ] {
            var compiled: SecRequirement?
            let status = SecRequirementCreateWithString(try XCTUnwrap(requirement) as CFString, [], &compiled)
            XCTAssertEqual(status, errSecSuccess, requirement ?? "")
        }
    }

    func testTheTestProcessReportsNoTeamOrAWellFormedOne() {
        if let team = HomeHelperIdentity.ownTeamIdentifier() {
            XCTAssertTrue(HomeHelperIdentity.isValidTeamIdentifier(team))
        }
    }

    func testTheLaunchAgentTemplateMatchesTheNamesTheCodeUses() throws {
        let app = "com.example.imcp"
        let template = try Self.repositoryFile("Scripts/home-helper.launchd.plist.in")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(
                    String(decoding: template, as: UTF8.self).replacingOccurrences(
                        of: "__APP_BUNDLE_IDENTIFIER__",
                        with: app
                    ).utf8
                ),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, HomeHelperIdentity.agentLabel(appBundleIdentifier: app))
        let services = try XCTUnwrap(plist["MachServices"] as? [String: Bool])
        XCTAssertEqual(Array(services.keys), [HomeHelperIdentity.machServiceName(appBundleIdentifier: app)])
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [app])
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            HomeHelperIdentity.embeddedHelperRelativePath + "/Contents/MacOS/iMCP Helper"
        )
    }

    func testBothAppEntitlementsLetTheSandboxLookUpTheMachService() throws {
        for file in ["App/App.entitlements", "App/App.Debug.entitlements"] {
            let entitlements = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: Self.repositoryFile(file), format: nil) as? [String: Any]
            )
            let names = try XCTUnwrap(
                entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String]
            )
            XCTAssertTrue(names.contains("$(PRODUCT_BUNDLE_IDENTIFIER).home-xpc"), file)
        }
    }

    static func repositoryFile(_ path: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(path))
    }
}

final class HomeHelperLocatorTests: XCTestCase {
    func testStateFollowsWhatIsBundledAndWhatMacOSReports() {
        typealias Locator = HomeHelperLocator
        XCTAssertEqual(Locator.state(isBundled: false, status: .enabled), .notBundled)
        XCTAssertEqual(Locator.state(isBundled: false, status: .notFound), .notBundled)
        // A never-registered agent reports notFound.
        XCTAssertEqual(Locator.state(isBundled: true, status: .notFound), .notRegistered)
        XCTAssertEqual(Locator.state(isBundled: true, status: .notRegistered), .notRegistered)
        XCTAssertEqual(Locator.state(isBundled: true, status: .requiresApproval), .needsApproval)
        XCTAssertEqual(Locator.state(isBundled: true, status: .enabled), .registered)
    }

    func testLocationsAreInsideTheAppBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/iMCP.app")
        XCTAssertEqual(
            HomeHelperLocator.embeddedHelperURL(in: bundle).path,
            "/Applications/iMCP.app/Contents/Helpers/iMCP Helper.app"
        )
        XCTAssertEqual(
            HomeHelperLocator.agentPlistURL(in: bundle, appBundleIdentifier: "com.example.imcp").path,
            "/Applications/iMCP.app/Contents/Library/LaunchAgents/com.example.imcp.home-helper.plist"
        )
    }

    func testABundleCountsOnlyWithTheMarkedHelperAndTheAgentPlist() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertFalse(HomeHelperLocator.isBundled(in: fixture.bundle, appBundleIdentifier: fixture.appIdentifier))
        try fixture.writeHelper(marked: false)
        try fixture.writeAgentPlist()
        XCTAssertFalse(
            HomeHelperLocator.isBundled(in: fixture.bundle, appBundleIdentifier: fixture.appIdentifier),
            "An app without the iMCPHelper marker is not the helper."
        )
        try fixture.writeHelper(marked: true)
        XCTAssertTrue(HomeHelperLocator.isBundled(in: fixture.bundle, appBundleIdentifier: fixture.appIdentifier))
        XCTAssertEqual(
            HomeHelperLocator.helperBundleIdentifier(at: HomeHelperLocator.embeddedHelperURL(in: fixture.bundle)),
            fixture.helperIdentifier
        )
        try FileManager.default.removeItem(
            at: HomeHelperLocator.agentPlistURL(in: fixture.bundle, appBundleIdentifier: fixture.appIdentifier)
        )
        XCTAssertFalse(HomeHelperLocator.isBundled(in: fixture.bundle, appBundleIdentifier: fixture.appIdentifier))
    }
}

final class HomeServiceRegistrationTests: XCTestCase {
    func testRegistersAnUnregisteredAgentAndLeavesARegisteredOneAlone() async throws {
        let fixture = try Fixture(bundled: true)
        defer { fixture.remove() }
        let agent = FakeAgent(status: .notRegistered)
        let service = fixture.service(agent: agent)
        XCTAssertEqual(service.state(), .notRegistered)
        try await service.register()
        XCTAssertEqual(agent.registerCalls, 1)
        XCTAssertEqual(service.state(), .registered)
        try await service.register()
        XCTAssertEqual(agent.registerCalls, 1)
    }

    func testSendsTheUserToLoginItemsWhenMacOSWantsApproval() async throws {
        let fixture = try Fixture(bundled: true)
        defer { fixture.remove() }
        let waiting = FakeAgent(status: .requiresApproval)
        do {
            try await fixture.service(agent: waiting).register()
            XCTFail("An agent that needs approval isn't registered.")
        } catch let error as HomeService.SetupError {
            XCTAssertEqual(error, .needsApproval)
        }
        XCTAssertEqual(waiting.settingsOpened, 1)
        XCTAssertEqual(waiting.registerCalls, 0)

        // Registering can itself report that approval is missing.
        let throwing = FakeAgent(
            status: .notRegistered,
            registerError: NSError(domain: "x", code: 1),
            statusAfterRegisterFailure: .requiresApproval
        )
        do {
            try await fixture.service(agent: throwing).register()
            XCTFail("A failed registration that needs approval must say so.")
        } catch let error as HomeService.SetupError {
            XCTAssertEqual(error, .needsApproval)
        }
        XCTAssertEqual(throwing.settingsOpened, 1)
    }

    func testAnOrdinaryRegistrationFailureKeepsItsMessage() async throws {
        let fixture = try Fixture(bundled: true)
        defer { fixture.remove() }
        let agent = FakeAgent(
            status: .notRegistered,
            registerError: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch denied."])
        )
        do {
            try await fixture.service(agent: agent).register()
            XCTFail("The failure must reach the caller.")
        } catch let error as HomeService.SetupError {
            XCTAssertEqual(error, .registrationFailed("Launch denied."))
        }
        XCTAssertEqual(agent.settingsOpened, 0)
    }

    func testABuildWithoutTheHelperCannotRegister() async throws {
        let fixture = try Fixture(bundled: false)
        defer { fixture.remove() }
        let agent = FakeAgent(status: .notFound)
        do {
            try await fixture.service(agent: agent).register()
            XCTFail("There is nothing to register.")
        } catch let error as HomeService.SetupError {
            XCTAssertEqual(error, .notBundled)
        }
        XCTAssertEqual(agent.registerCalls, 0)
    }

    func testUnregisteringIsTheNewUnpair() async throws {
        let fixture = try Fixture(bundled: true)
        defer { fixture.remove() }
        let agent = FakeAgent(status: .enabled)
        let service = fixture.service(agent: agent)
        try await service.unregister()
        XCTAssertEqual(agent.unregisterCalls, 1)
        XCTAssertEqual(service.state(), .notRegistered)
        let activated = await service.isActivated
        XCTAssertFalse(activated)
        try await service.register()
        XCTAssertEqual(agent.registerCalls, 1)
        XCTAssertEqual(service.state(), .registered)
    }

    func testAnApprovalWaitingServiceTurnsHomeOffInsteadOfThrowing() async throws {
        let fixture = try Fixture(bundled: true)
        defer { fixture.remove() }
        let service = fixture.service(agent: FakeAgent(status: .requiresApproval))
        let activated = try await service.activateAskingUser()
        XCTAssertFalse(activated)
    }
}

// MARK: - Helpers

private actor RecordingBackend: HomeBackend {
    var calls: [String] = []
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        calls.append(tool)
        return .object(input)
    }
}

private struct FailingBackend: HomeBackend {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value { throw HomeError("HomeKit refused.") }
}

private final class FakeAgent: HomeAgentControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SMAppService.Status
    private let registerError: Error?
    private let statusAfterRegisterFailure: SMAppService.Status?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var settingsOpened = 0

    init(
        status: SMAppService.Status,
        registerError: Error? = nil,
        statusAfterRegisterFailure: SMAppService.Status? = nil
    ) {
        current = status
        self.registerError = registerError
        self.statusAfterRegisterFailure = statusAfterRegisterFailure
    }

    var status: SMAppService.Status {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        registerCalls += 1
        if let registerError {
            if let statusAfterRegisterFailure { current = statusAfterRegisterFailure }
            throw registerError
        }
        current = .enabled
    }

    func unregister() async throws {
        unregistered()
    }

    private func unregistered() {
        lock.lock()
        defer { lock.unlock() }
        unregisterCalls += 1
        current = .notRegistered
    }

    func openLoginItemsSettings() {
        lock.lock()
        defer { lock.unlock() }
        settingsOpened += 1
    }
}

/// A throwaway app bundle that carries, or lacks, the helper and its agent plist.
private struct Fixture {
    let root: URL
    let bundle: URL
    let appIdentifier = "com.example.imcp"
    let helperIdentifier = "com.example.imcp.helper"

    init(bundled: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("imcp-home-\(UUID().uuidString)")
        bundle = root.appendingPathComponent("iMCP.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if bundled {
            try writeHelper(marked: true)
            try writeAgentPlist()
        }
    }

    func writeHelper(marked: Bool) throws {
        let contents = HomeHelperLocator.embeddedHelperURL(in: bundle).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": helperIdentifier]
        if marked { info[HomeHelperIdentity.markerKey] = true }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    func writeAgentPlist() throws {
        let url = HomeHelperLocator.agentPlistURL(in: bundle, appBundleIdentifier: appIdentifier)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: url)
    }

    func service(agent: any HomeAgentControlling) -> HomeService {
        HomeService(bundleURL: bundle, appBundleIdentifier: appIdentifier, agent: agent)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
