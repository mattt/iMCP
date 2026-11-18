import CryptoKit
import Foundation
import JSONSchema
import MCP
import Network
import XCTest

final class MobileConfigurationTests: XCTestCase {
    private func state(
        order: [MobileRouteKind] = MobileRouteKind.defaultOrder,
        disabled: Set<MobileRouteKind> = [],
        mode: MobileTransportMode = .automatic
    ) -> MobileMacState {
        MobileMacState(
            macName: "Studio",
            service: "iMCP on Studio",
            recommendedMode: mode,
            order: order,
            disabled: disabled,
            tailnetHost: "studio.tail.ts.net",
            tailnetPort: 4628,
            funnelURL: "wss://studio.tail.ts.net/mobile",
            cloudflareURL: "https://imcp.example.com"
        )
    }

    // MARK: - Encoding and compatibility

    func testConfigurationRoundTrips() throws {
        let configuration = MobileConfigurationBuilder.build(state(), revision: 7)
        let data = try MobileCoding.encoder.encode(configuration)
        XCTAssertEqual(try MobileCoding.decoder.decode(MobileConfiguration.self, from: data), configuration)
    }

    func testWelcomeFromAnOlderMacHasNoConfiguration() throws {
        let json = #"{"ok":true,"mac":"iMCP on Studio","tailnetHost":"h","tailnetPort":4628}"#
        let welcome = try MobileCoding.decoder.decode(MobileWelcome.self, from: Data(json.utf8))
        XCTAssertNil(welcome.configuration)
        XCTAssertEqual(welcome.tailnetHost, "h")
    }

    func testWelcomeKeepsTheIndividualEndpointsBesideTheConfiguration() throws {
        var welcome = MobileWelcome(ok: true, tailnetHost: "h", tailnetPort: 1, cloudflareURL: "wss://c/mobile")
        welcome.configuration = MobileConfigurationBuilder.build(state(), revision: 2)
        let decoded = try MobileCoding.decoder.decode(MobileWelcome.self, from: MobileCoding.encoder.encode(welcome))
        XCTAssertEqual(decoded, welcome)
        XCTAssertEqual(decoded.tailnetHost, "h")
    }

    func testAConfigurationFromANewerMacStillDecodes() throws {
        let json = """
            {"schema":2,"revision":4,"macName":"Studio","service":"iMCP on Studio","recommendedMode":"quantum",
             "routes":[{"kind":"local","label":"Local Network"},{"kind":"carrierPigeon","label":"Pigeon"},
                       {"kind":"cloudflare","label":"Cloudflare Tunnel","url":"wss://c/mobile","extra":1}],
             "features":{"approvals":true,"newThing":true},"somethingNew":{}}
            """
        let configuration = try MobileCoding.decoder.decode(MobileConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.routes.map(\.kind), [.local, .cloudflare])
        XCTAssertEqual(configuration.recommendedMode, .automatic)
        XCTAssertTrue(configuration.features.approvals)
        XCTAssertTrue(configuration.features.activityHistory)
    }

    // MARK: - The order the Mac produces

    func testDefaultOrderIsLocalCloudflareVPNFunnel() {
        let configuration = MobileConfigurationBuilder.build(state(), revision: 1)
        XCTAssertEqual(configuration.routes.map(\.kind), [.local, .cloudflare, .tailscaleVPN, .tailscaleFunnel])
        XCTAssertEqual(configuration.tailnetHost, "studio.tail.ts.net")
        XCTAssertEqual(configuration.tailnetPort, 4628)
        XCTAssertEqual(configuration.cloudflareURL, "wss://imcp.example.com/mobile")
        XCTAssertEqual(configuration.funnelURL, "wss://studio.tail.ts.net/mobile")
    }

    func testTheOwnersOrderAndDisabledRoutesAreFollowed() {
        let configuration = MobileConfigurationBuilder.build(
            state(order: [.tailscaleFunnel, .local], disabled: [.cloudflare]),
            revision: 1
        )
        // Kinds the owner didn't place follow in the default order.
        XCTAssertEqual(configuration.routes.map(\.kind), [.tailscaleFunnel, .local, .tailscaleVPN])
    }

    func testARouteWithoutAnAddressIsNotOffered() {
        var mac = state()
        mac.funnelURL = nil
        mac.tailnetHost = "  "
        let entries = MobileConfigurationBuilder.entries(mac)
        XCTAssertEqual(entries.filter(\.isOffered).map(\.kind), [.local, .cloudflare])
        XCTAssertEqual(entries.first { $0.kind == .tailscaleFunnel }?.address, nil)
    }

    func testALocalOnlyMacOffersOnlyTheLocalRoute() {
        let configuration = MobileConfigurationBuilder.build(state(mode: .localOnly), revision: 1)
        XCTAssertEqual(configuration.routes.map(\.kind), [.local])
        XCTAssertEqual(configuration.recommendedMode, .localOnly)
    }

    func testNormalizedOrderDropsRepeats() {
        XCTAssertEqual(
            MobileConfigurationBuilder.normalizedOrder([.cloudflare, .cloudflare, .local]),
            [.cloudflare, .local, .tailscaleVPN, .tailscaleFunnel]
        )
    }

    // MARK: - The phone follows the Mac's order

    func testAutomaticDialsRoutesInTheMacsOrder() {
        let configuration = MobileConfigurationBuilder.build(state(order: [.tailscaleVPN, .local]), revision: 1)
        XCTAssertEqual(
            configuration.candidates(for: .automatic).map(\.mode),
            [.tailscaleVPN, .localOnly, .cloudflare, .tailscaleFunnel]
        )
    }

    func testAutomaticFollowsTheModeTheMacRecommends() {
        let configuration = MobileConfigurationBuilder.build(state(mode: .cloudflare), revision: 1)
        XCTAssertEqual(configuration.candidates(for: .automatic).map(\.mode), [.cloudflare])
    }

    func testAnExplicitModeUsesOneRoute() {
        let configuration = MobileConfigurationBuilder.build(state(), revision: 1)
        XCTAssertEqual(configuration.candidates(for: .tailscaleVPN).map(\.mode), [.tailscaleVPN])
        XCTAssertEqual(
            configuration.candidates(for: .tailscaleVPN),
            [.tailscaleVPN(host: "studio.tail.ts.net", port: 4628)]
        )
        XCTAssertEqual(configuration.candidates(for: .localOnly), [.bonjour(service: "iMCP on Studio")])
    }

    func testAModeTheMacDoesNotOfferHasNoCandidates() {
        let configuration = MobileConfigurationBuilder.build(state(disabled: [.tailscaleFunnel]), revision: 1)
        XCTAssertTrue(configuration.candidates(for: .tailscaleFunnel).isEmpty)
    }

    // MARK: - Revisions, and replacing instead of merging

    private func routes(_ revision: Int?, mac: MobileMacState) -> MobilePhoneRoutes {
        MobilePhoneRoutes(
            service: "iMCP on Studio",
            tailnetHost: "baked.example",
            tailnetPort: 4628,
            funnelURL: "wss://baked/mobile",
            cloudflareURL: "wss://baked-cf/mobile",
            configuration: revision.map { MobileConfigurationBuilder.build(mac, revision: $0) }
        )
    }

    func testAPhoneNeverAppliesAnOlderOrEqualRevision() {
        let held = routes(5, mac: state())
        var changed = state()
        changed.cloudflareURL = nil
        XCTAssertNil(held.applying(MobileConfigurationBuilder.build(changed, revision: 4)))
        XCTAssertNil(held.applying(MobileConfigurationBuilder.build(changed, revision: 5)))
        XCTAssertEqual(
            held.applying(MobileConfigurationBuilder.build(changed, revision: 6))?.configuration?.revision,
            6
        )
    }

    func testAnOlderWelcomeLeavesTheHeldConfigurationAlone() {
        let held = routes(5, mac: state())
        var welcome = MobileWelcome(ok: true, tailnetHost: "stale")
        welcome.configuration = MobileConfigurationBuilder.build(state(disabled: [.local]), revision: 3)
        XCTAssertEqual(held.updating(from: welcome), held)
    }

    func testANewConfigurationReplacesSavedRoutesAndClearsTheOnesNoLongerOffered() throws {
        var mac = state()
        mac.cloudflareURL = nil
        mac.funnelURL = nil
        mac.tailnetHost = "new.tail.ts.net"
        mac.tailnetPort = 5000
        // Starts from baked-in addresses and nothing learned.
        let learned = try XCTUnwrap(routes(nil, mac: mac).applying(MobileConfigurationBuilder.build(mac, revision: 1)))
        XCTAssertEqual(learned.tailnetHost, "new.tail.ts.net")
        XCTAssertEqual(learned.tailnetPort, 5000)
        XCTAssertNil(learned.funnelURL)
        XCTAssertNil(learned.cloudflareURL)
        XCTAssertEqual(learned.candidates(for: .automatic).map(\.mode), [.localOnly, .tailscaleVPN])
        XCTAssertTrue(learned.candidates(for: .cloudflare).isEmpty)
    }

    func testAWelcomeWithoutAConfigurationStillMergesEndpoints() {
        let held = MobilePhoneRoutes(service: "iMCP on Studio")
        let merged = held.updating(
            from: MobileWelcome(ok: true, tailnetHost: "h", tailnetPort: 9, funnelURL: "f.example")
        )
        XCTAssertEqual(merged.tailnetHost, "h")
        XCTAssertEqual(merged.funnelURL, "wss://f.example/mobile")
        XCTAssertNil(merged.configuration)
        XCTAssertEqual(merged.candidates(for: .automatic).map(\.mode), [.localOnly, .tailscaleVPN, .tailscaleFunnel])
    }

    // MARK: - The Mac's ledger

    private func makeDefaults() -> UserDefaults {
        let name = "MobileConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheRevisionOnlyGoesUpWhenTheOfferChanges() {
        let defaults = makeDefaults()
        let ledger = MobileConfigurationLedger(defaults: defaults)
        XCTAssertEqual(ledger.configuration(for: state()).revision, 1)
        XCTAssertEqual(ledger.configuration(for: state()).revision, 1)
        // A relaunch with the same settings keeps the revision.
        XCTAssertEqual(MobileConfigurationLedger(defaults: defaults).configuration(for: state()).revision, 1)
        XCTAssertEqual(ledger.configuration(for: state(order: [.tailscaleFunnel])).revision, 2)
        XCTAssertEqual(ledger.configuration(for: state(order: [.tailscaleFunnel])).revision, 2)
        // Going back is a new revision, not the old number.
        XCTAssertEqual(ledger.configuration(for: state()).revision, 3)
    }

    func testTheLedgerRemembersWhatEachPhoneApplied() {
        let ledger = MobileConfigurationLedger(defaults: makeDefaults())
        XCTAssertNil(ledger.appliedRevision(for: "a"))
        ledger.recordApplied(3, for: "a")
        ledger.recordApplied(2, for: "b")
        XCTAssertEqual(ledger.appliedRevision(for: "a"), 3)
        ledger.forget("a")
        XCTAssertNil(ledger.appliedRevision(for: "a"))
        XCTAssertEqual(ledger.appliedRevision(for: "b"), 2)
    }
}

// MARK: - The Mac service end to end

final class MobileConfigurationDeliveryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var pairings: MobileMemoryPairings!
    private var service: MobileService!
    private var port: UInt16 = 0
    private var phoneChannels: [any MobileTransportChannel] = []
    private var phoneTasks: [Task<Void, Error>] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "MobileConfigurationDeliveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        // A fixed host keeps the test off the machine's real Tailscale interface.
        defaults.set("mac.tail.ts.net", forKey: MobileService.tailscaleHostOverrideKey)
        pairings = MobileMemoryPairings()
        service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            activityStore: try MobileActivityStore(url: directory.appendingPathComponent("activity.json")),
            pairings: pairings,
            defaults: defaults,
            reconnectGrace: .milliseconds(500),
            advertise: false,
            pollInterval: .seconds(60)
        )
    }

    override func tearDown() async throws {
        for task in phoneTasks { task.cancel() }
        await service.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func connect(
        _ credentials: MobileDialer.Credentials,
        tools: [Tool] = []
    ) async throws -> MobileDialer.Session {
        if let current = await service.listeningPort { port = current }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let session = try await MobileDialer.connect(to: endpoint, with: credentials, timeout: .seconds(3))
        phoneChannels.append(session.channel)
        phoneTasks.append(Task { try await MobilePeer.serve(session.channel, tools: tools, version: "test") })
        return session
    }

    /// A phone that holds `revision` and applies anything newer, like the real one.
    private func configTool(_ held: HeldRevision) -> Tool {
        Tool(
            name: MobileConfigLink.applyTool,
            description: "Receive the Mac's configuration.",
            inputSchema: .object(properties: [:], additionalProperties: true),
            annotations: .init(readOnlyHint: false, openWorldHint: false)
        ) { input in
            let request = try MobileCoding.decoder.decode(
                MobileConfigApplyRequest.self,
                from: JSONEncoder().encode(input)
            )
            let response = await held.apply(request.configuration)
            return try JSONDecoder().decode(Value.self, from: MobileCoding.encoder.encode(response))
        }
    }

    private func waitFor(_ description: String, _ condition: () async -> Bool) async throws {
        for _ in 0 ..< 100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(description).")
    }

    func testPairingAndEveryReconnectCarryTheConfigurationInTheWelcome() async throws {
        let code = try await service.beginPairing()
        let first = try await connect(MobileDialer.pairing(code, device: "phone-1", name: "iPhone"))
        let paired = try XCTUnwrap(first.welcome.configuration)
        XCTAssertEqual(paired.macName, Host.current().localizedName ?? "Mac")
        XCTAssertEqual(paired.routes.map(\.kind), [.local, .tailscaleVPN])
        XCTAssertEqual(paired.tailnetHost, "mac.tail.ts.net")
        // The individual fields stay for phones that predate configurations.
        XCTAssertEqual(first.welcome.tailnetHost, "mac.tail.ts.net")
        XCTAssertEqual(first.welcome.configuration?.revision, paired.revision)

        let key = try XCTUnwrap(first.deviceKey)
        await service.disconnect()
        let again = try await connect(MobileDialer.paired(device: "phone-1", name: "iPhone", key: key))
        XCTAssertEqual(again.welcome.configuration, paired)
    }

    func testTheMacRecordsTheRevisionThePhoneApplied() async throws {
        let held = HeldRevision()
        let code = try await service.beginPairing()
        _ = try await connect(
            MobileDialer.pairing(code, device: "phone-1", name: "iPhone"),
            tools: [configTool(held)]
        )
        let revision = await service.currentConfiguration.revision
        try await waitFor("the phone's acknowledgement") {
            await service.appliedConfigurationRevision(for: "phone-1") == revision
        }
        let applied = await held.revision
        XCTAssertEqual(applied, revision)
    }

    func testChangingTheMacsSettingsPushesANewRevisionToTheConnectedPhone() async throws {
        let held = HeldRevision()
        let code = try await service.beginPairing()
        _ = try await connect(
            MobileDialer.pairing(code, device: "phone-1", name: "iPhone"),
            tools: [configTool(held)]
        )
        let before = await service.currentConfiguration.revision
        try await waitFor("the first acknowledgement") {
            await service.appliedConfigurationRevision(for: "phone-1") == before
        }

        MobileService.setRouteOrder([.tailscaleVPN, .local], defaults: defaults)
        await service.applyTransportSettings()
        let after = await service.currentConfiguration
        XCTAssertEqual(after.revision, before + 1)
        XCTAssertEqual(after.routes.map(\.kind), [.tailscaleVPN, .local])
        try await waitFor("the phone to apply the new order") {
            await held.configuration?.routes.map(\.kind) == [.tailscaleVPN, .local]
        }
        let acknowledged = await service.appliedConfigurationRevision(for: "phone-1")
        XCTAssertEqual(acknowledged, after.revision)

        MobileService.setRoute(.tailscaleVPN, enabled: false, defaults: defaults)
        await service.applyTransportSettings()
        try await waitFor("the phone to drop the route") {
            await held.configuration?.routes.map(\.kind) == [.local]
        }
    }

    func testAPhoneThatPredatesConfigurationsIsLeftAlone() async throws {
        let code = try await service.beginPairing()
        _ = try await connect(MobileDialer.pairing(code, device: "old-phone", name: "iPhone"))
        try await waitFor("the link") { await service.isConnected }
        await service.pushConfiguration()
        let applied = await service.appliedConfigurationRevision(for: "old-phone")
        XCTAssertNil(applied)
        let connected = await service.isConnected
        XCTAssertTrue(connected)
    }

    func testUnpairingForgetsTheAcknowledgement() async throws {
        let held = HeldRevision()
        let code = try await service.beginPairing()
        _ = try await connect(
            MobileDialer.pairing(code, device: "phone-1", name: "iPhone"),
            tools: [configTool(held)]
        )
        try await waitFor("the acknowledgement") {
            await service.appliedConfigurationRevision(for: "phone-1") != nil
        }
        await service.unpair("phone-1")
        let applied = await service.appliedConfigurationRevision(for: "phone-1")
        XCTAssertNil(applied)
    }
}

/// What the phone's `config_apply` tool does: keep the newest revision and say which one it holds.
private actor HeldRevision {
    private(set) var configuration: MobileConfiguration?

    var revision: Int { configuration?.revision ?? 0 }

    func apply(_ new: MobileConfiguration) -> MobileConfigApplyResponse {
        guard new.supersedes(configuration) else {
            return MobileConfigApplyResponse(revision: revision, applied: false)
        }
        configuration = new
        return MobileConfigApplyResponse(revision: new.revision, applied: true)
    }
}

extension MobilePhoneRoutes {
    fileprivate init(service: String) {
        self.init(
            service: service,
            tailnetHost: nil,
            tailnetPort: nil,
            funnelURL: nil,
            cloudflareURL: nil,
            configuration: nil
        )
    }
}
