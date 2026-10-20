import CryptoKit
import JSONSchema
import Network
import XCTest

final class MobileLinkTests: XCTestCase {
    private var directory: URL!
    private var pairings: MobileMemoryPairings!
    private var service: MobileService!
    private var port: UInt16 = 0
    private var enabled: Flag!
    private var phoneTasks: [Task<Void, Error>] = []
    private var phoneChannels: [MobileChannel] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pairings = MobileMemoryPairings()
        enabled = Flag(true)
        service = makeService()
    }

    private func makeService(codeLifetime: TimeInterval = MobileService.pairingLifetime) -> MobileService {
        let enabled = self.enabled!
        return MobileService(
            cache: try? MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: pairings,
            reconnectGrace: .milliseconds(500),
            advertise: false,
            pollInterval: .seconds(60),
            codeLifetime: codeLifetime,
            isEnabled: { enabled.value }
        )
    }

    override func tearDown() async throws {
        for task in phoneTasks { task.cancel() }
        await service.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private var endpoint: NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// Connects as the phone and serves `tools` until the test ends.
    @discardableResult
    private func connectPhone(
        _ credentials: MobileDialer.Credentials,
        tools: [Tool] = []
    ) async throws -> MobileDialer.Session {
        // The listener keeps its port when it restarts, and the last one stays after it stops.
        if let current = await service.listeningPort { port = current }
        let session = try await MobileDialer.connect(to: endpoint, with: credentials, timeout: .seconds(3))
        phoneChannels.append(session.channel)
        phoneTasks.append(Task { try await MobilePeer.serve(session.channel, tools: tools, version: "test") })
        return session
    }

    private func waitUntilConnected(_ expected: Bool = true) async throws {
        for _ in 0 ..< 100 {
            if await service.isConnected == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The phone did not \(expected ? "connect" : "disconnect").")
    }

    func testPairingAuthenticatesAndServesLiveCalls() async throws {
        let code = try await service.beginPairing()
        XCTAssertEqual(MobilePairingCode(url: code.url), code)
        let welcome = try await connectPhone(
            MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"),
            tools: [phoneTool("alarms_list") { _ in ["source": "live", "results": []] }]
        )
        XCTAssertTrue(welcome.welcome.ok)
        XCTAssertEqual(welcome.deviceKey?.bitCount, 256)
        XCTAssertEqual(pairings.devices().map(\.id), ["phone-1"])
        try await waitUntilConnected()

        let value = try await service.call("alarms_list", [:])
        XCTAssertEqual(value.objectValue?["source"], "live")
        let status = try await service.call("mobile_status", [:])
        XCTAssertEqual(status.objectValue?["connected"], true)
        XCTAssertEqual(status.objectValue?["device"], "Test iPhone")
    }

    func testPairingSendsNoKeyMaterial() async throws {
        let code = try await service.beginPairing()
        let credentials = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        let session = try await connectPhone(credentials)
        let key = try XCTUnwrap(session.deviceKey).withUnsafeBytes { Data($0) }
        let wire =
            try MobileCoding.encoder.encode(credentials.hello) + MobileCoding.encoder.encode(session.welcome)
        XCTAssertNil(wire.range(of: key))
        XCTAssertNil(wire.range(of: Data(key.base64EncodedString().utf8)))
        // Someone who copied the QR code and recorded the handshake knows the pairing key
        // and both public keys, but not the private ones, so can't derive the device key.
        let observed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: MobileLink.pairingKey(secret: code.secret),
            info: (credentials.hello.exchange ?? Data()) + (session.welcome.exchange ?? Data()),
            outputByteCount: 32
        )
        XCTAssertNotEqual(observed.withUnsafeBytes { Data($0) }, key)
    }

    func testPairingRejectsASwappedExchangeKey() async throws {
        let code = try await service.beginPairing()
        var credentials = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        credentials.hello.exchange = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        do {
            try await connectPhone(credentials)
            XCTFail("A hello whose exchange key its proof doesn't cover must be refused.")
        } catch {}
        XCTAssertTrue(pairings.devices().isEmpty)
    }

    func testPairingCodeWorksOnce() async throws {
        let code = try await service.beginPairing()
        try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        do {
            try await connectPhone(MobileDialer.pairing(code, device: "phone-2", name: "Other iPhone"))
            XCTFail("A pairing code must not work twice.")
        } catch {}
        XCTAssertEqual(pairings.devices().map(\.id), ["phone-1"])
    }

    func testPairedDeviceReconnectsWithItsKey() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = try XCTUnwrap(welcome.deviceKey)
        try await waitUntilConnected()
        await service.disconnect()
        try await waitUntilConnected(false)
        // With a pairing code on screen, the listener holds two keys
        // and must choose the device's key by its identity.
        _ = try await service.beginPairing()

        let again = try await connectPhone(MobileDialer.paired(device: "phone-1", name: "Test iPhone", key: key))
        XCTAssertTrue(again.welcome.ok)
        XCTAssertNil(again.deviceKey)
        try await waitUntilConnected()
    }

    func testWrongPairingSecretIsRejected() async throws {
        let code = try await service.beginPairing()
        var wrong = code
        wrong.secret = Data(repeating: 7, count: 32)
        do {
            try await connectPhone(MobileDialer.pairing(wrong, device: "phone-1", name: "Intruder"))
            XCTFail("A wrong pairing secret must be rejected.")
        } catch {}
        XCTAssertTrue(pairings.devices().isEmpty)
        let connected = await service.isConnected
        XCTAssertFalse(connected)
    }

    func testUnknownDeviceKeyIsRejected() async throws {
        _ = try await service.beginPairing()
        do {
            try await connectPhone(
                MobileDialer.paired(device: "phone-9", name: "Stranger", key: SymmetricKey(size: .bits256))
            )
            XCTFail("An unpaired device must be rejected.")
        } catch {}
    }

    func testMacCanRevokeAPairing() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = try XCTUnwrap(welcome.deviceKey)
        try await waitUntilConnected()
        await service.unpair("phone-1")
        try await waitUntilConnected(false)
        XCTAssertTrue(pairings.devices().isEmpty)
        let listening = await service.listeningPort
        XCTAssertNil(listening, "With no paired device, iMCP stops listening.")
        do {
            try await connectPhone(MobileDialer.paired(device: "phone-1", name: "Test iPhone", key: key))
            XCTFail("A revoked device must be rejected.")
        } catch {}
    }

    func testPhoneCanRevokeItsPairing() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = try XCTUnwrap(welcome.deviceKey)
        let before = await service.cacheID
        let goodbye = try await connectPhone(
            MobileDialer.paired(device: "phone-1", name: "Test iPhone", key: key, revoke: true)
        )
        XCTAssertTrue(goodbye.welcome.ok)
        XCTAssertTrue(pairings.devices().isEmpty)
        let listening = await service.listeningPort
        XCTAssertNil(listening, "With no paired device, iMCP stops listening.")
        let after = await service.cacheID
        XCTAssertNotEqual(after, before, "Removing the last pairing deletes the cache.")
    }

    func testSyncPullAppliesBatchesAndAcknowledgesThem() async throws {
        let acknowledged = Recorder<Int>()
        let cacheIDs = Recorder<String>()
        let sent = Recorder<Bool>()
        let record = MobileRecord(
            kind: .alarm,
            id: "alarm-1",
            key: nil,
            start: nil,
            end: nil,
            payload: Data(#"{"id":"alarm-1","title":"Wake"}"#.utf8)
        )
        let syncedAt = Date()
        let tools = [
            phoneTool(MobileLink.pullTool) { input in
                if let id = input["cache"]?.stringValue { await cacheIDs.append(id) }
                if await sent.values.isEmpty {
                    await sent.append(true)
                    let batch = MobileBatch(
                        sequence: 7,
                        syncedAt: ["alarms": syncedAt],
                        records: [record],
                        replacing: [.alarm]
                    )
                    return try JSONDecoder().decode(Value.self, from: MobileCoding.encoder.encode(batch))
                }
                return try JSONDecoder().decode(
                    Value.self,
                    from: MobileCoding.encoder.encode(MobileBatch(sequence: 0, syncedAt: [:], records: []))
                )
            },
            phoneTool(MobileLink.ackTool) { input in
                await acknowledged.append(input["sequence"]?.intValue ?? -1)
                return ["ok": true]
            },
        ]
        let code = try await service.beginPairing()
        try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"), tools: tools)
        for _ in 0 ..< 100 where await acknowledged.values.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let acks = await acknowledged.values
        XCTAssertEqual(acks, [7])
        let ids = await cacheIDs.values
        let cacheID = await service.cacheID
        XCTAssertEqual(ids.first, cacheID)

        await service.disconnect()
        try await waitUntilConnected(false)
        let offline = try await service.call("alarms_list", [:])
        XCTAssertEqual(offline.objectValue?["source"], "cache")
        XCTAssertEqual(offline.objectValue?["results"]?.arrayValue?.first?.objectValue?["title"], "Wake")
    }

    func testPhoneDisconnectDuringALiveCallFallsBackToTheCache() async throws {
        let started = Recorder<Bool>()
        let code = try await service.beginPairing()
        try await connectPhone(
            MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"),
            tools: [
                phoneTool("workouts_fetch") { _ in
                    await started.append(true)
                    try await Task.sleep(for: .seconds(600))
                    return [:]
                }
            ]
        )
        try await waitUntilConnected()
        let call = Task { try await service.call("workouts_fetch", [:]) }
        for _ in 0 ..< 100 where await started.values.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let clock = ContinuousClock()
        let begin = clock.now
        await phoneChannels.last?.disconnect()
        let value = try await call.value
        XCTAssertEqual(value.objectValue?["source"], "cache")
        XCTAssertLessThan(clock.now - begin, .seconds(5))
    }

    func testSyncContinuesAfterThePhoneDropsDuringAPull() async throws {
        let pulls = Recorder<Int>()
        let acknowledged = Recorder<Int>()
        let record = MobileRecord(
            kind: .alarm,
            id: "alarm-1",
            key: nil,
            start: nil,
            end: nil,
            payload: Data(#"{"id":"alarm-1"}"#.utf8)
        )
        let tools = [
            phoneTool(MobileLink.pullTool) { _ in
                await pulls.append(1)
                if await pulls.values.count == 1 {
                    // The first phone stops answering, as an app does when iOS suspends it.
                    try await Task.sleep(for: .seconds(600))
                }
                let batch = MobileBatch(
                    sequence: await acknowledged.values.isEmpty ? 3 : 0,
                    syncedAt: [:],
                    records: [record]
                )
                return try JSONDecoder().decode(Value.self, from: MobileCoding.encoder.encode(batch))
            },
            phoneTool(MobileLink.ackTool) { input in
                await acknowledged.append(input["sequence"]?.intValue ?? -1)
                return ["ok": true]
            },
        ]
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(
            MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"),
            tools: tools
        )
        for _ in 0 ..< 100 where await pulls.values.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        await phoneChannels.last?.disconnect()
        try await waitUntilConnected(false)
        let key = try XCTUnwrap(welcome.deviceKey)
        try await connectPhone(
            MobileDialer.paired(device: "phone-1", name: "Test iPhone", key: key),
            tools: tools
        )
        for _ in 0 ..< 100 where await acknowledged.values.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let acks = await acknowledged.values
        XCTAssertEqual(acks, [3], "The second connection must drain the queue.")
    }

    func testNothingListensWithoutAPairedDeviceOrACode() async throws {
        try await service.start()
        let listening = await service.listeningPort
        XCTAssertNil(listening)
    }

    func testCancellingTheCodeStopsListening() async throws {
        _ = try await service.beginPairing()
        let during = await service.listeningPort
        XCTAssertNotNil(during)
        await service.cancelPairing()
        let after = await service.listeningPort
        XCTAssertNil(after)
    }

    func testAnExpiredCodeStopsListening() async throws {
        await service.stop()
        service = makeService(codeLifetime: 0.3)
        _ = try await service.beginPairing()
        let during = await service.listeningPort
        XCTAssertNotNil(during)
        for _ in 0 ..< 100 {
            if await service.listeningPort == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let after = await service.listeningPort
        XCTAssertNil(after, "An expired code must not keep the listener and its key.")
        let pairing = await service.isPairing
        XCTAssertFalse(pairing)
    }

    func testPairingKeepsListeningForTheDevice() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = try XCTUnwrap(welcome.deviceKey)
        let listening = await service.listeningPort
        XCTAssertNotNil(listening)
        let pairing = await service.isPairing
        XCTAssertFalse(pairing)
        await service.disconnect()
        try await waitUntilConnected(false)
        try await connectPhone(MobileDialer.paired(device: "phone-1", name: "Test iPhone", key: key))
        try await waitUntilConnected()
    }

    func testUnpairingOneOfTwoDevicesKeepsListening() async throws {
        for id in ["phone-1", "phone-2"] {
            let code = try await service.beginPairing()
            try await connectPhone(MobileDialer.pairing(code, device: id, name: id))
        }
        await service.unpair("phone-1")
        let listening = await service.listeningPort
        XCTAssertNotNil(listening)
    }

    func testTurningOffTheServicesStopsListening() async throws {
        let code = try await service.beginPairing()
        try await connectPhone(MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        try await waitUntilConnected()

        enabled.value = false
        await service.servicesChanged()
        let off = await service.listeningPort
        XCTAssertNil(off)
        try await waitUntilConnected(false)
        // A pairing code still works while the services are off.
        _ = try await service.beginPairing()
        let pairing = await service.listeningPort
        XCTAssertNotNil(pairing)
        await service.cancelPairing()

        enabled.value = true
        await service.servicesChanged()
        let on = await service.listeningPort
        XCTAssertNotNil(on)
    }

    func testDeletingTheCacheChangesItsIdentifier() async throws {
        let before = await service.cacheID
        try await service.deleteCache()
        let after = await service.cacheID
        XCTAssertNotEqual(before, after)
    }

    private func phoneTool(
        _ name: String,
        _ body: @escaping @Sendable ([String: Value]) async throws -> Value
    ) -> Tool {
        let schema: JSONSchema =
            MobileTools.all(backend: NoBackend()).first { $0.name == name }?.inputSchema ?? .object()
        return Tool(
            name: name,
            description: name,
            inputSchema: schema,
            annotations: .init(readOnlyHint: true),
            implementation: body
        )
    }
}

final class MobileRetryTests: XCTestCase {
    private var directory: URL!
    private var cache: MobileCache!
    private var pairings: MobileMemoryPairings!
    private var service: MobileService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = try MobileCache(
            url: directory.appendingPathComponent("cache.sqlite"),
            key: SymmetricKey(size: .bits256)
        )
        pairings = MobileMemoryPairings()
        service = MobileService(
            cache: cache,
            pairings: pairings,
            reconnectGrace: .milliseconds(300),
            advertise: false,
            pollInterval: .seconds(60)
        )
    }

    override func tearDown() async throws {
        await service.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreateReusesItsIdentifierAfterALostConnection() async throws {
        let first = FakeLink { _, _ in throw MobileLinkLost() }
        let second = FakeLink { _, input in #"{"id":"\#(input["id"]?.stringValue ?? "")","title":"Tea"}"# }
        await service.attach(first)
        let reconnect = Task {
            try await Task.sleep(for: .milliseconds(100))
            await service.attach(second)
        }
        let value = try await service.call("timers_create", ["title": "Tea", "duration_seconds": 180])
        _ = try await reconnect.value

        let sentFirst = try XCTUnwrap(first.calls.first { $0.tool == "timers_create" })
        let sentSecond = try XCTUnwrap(second.calls.first { $0.tool == "timers_create" })
        let id = try XCTUnwrap(sentFirst.input["id"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(sentSecond.input["id"]?.stringValue, id)
        XCTAssertEqual(value.objectValue?["id"]?.stringValue, id)
    }

    func testLostWriteIsNotRetriedOnAnotherDevice() async throws {
        let first = FakeLink(device: "iphone") { _, _ in throw MobileLinkLost() }
        let other = FakeLink(device: "ipad") { _, input in #"{"id":"\#(input["id"]?.stringValue ?? "")"}"# }
        await service.attach(first)
        let reconnect = Task {
            try await Task.sleep(for: .milliseconds(100))
            await service.attach(other)
        }
        do {
            _ = try await service.call("timers_create", ["title": "Tea", "duration_seconds": 180])
            XCTFail("A lost write must not succeed on another device.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("lost"))
        }
        _ = try await reconnect.value
        XCTAssertEqual(other.calls.filter { $0.tool == "timers_create" }.count, 0)
    }

    func testLostWriteWithoutReconnectReportsTheIdentifier() async throws {
        let link = FakeLink { _, _ in throw MobileLinkLost() }
        await service.attach(link)
        do {
            _ = try await service.call(
                "alarms_create",
                ["title": "Flight", "fire_at": "2030-01-01T06:00:00Z", "id": "8F0C2B8E-6E1A-4D53-9C0B-6A5D1A3E2F10"]
            )
            XCTFail("A lost write must not report success.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("8F0C2B8E-6E1A-4D53-9C0B-6A5D1A3E2F10"))
        }
        XCTAssertEqual(link.calls.filter { $0.tool == "alarms_create" }.count, 1)
    }

    func testLostReadWithoutReconnectFallsBackToTheCache() async throws {
        let link = FakeLink { _, _ in throw MobileLinkLost() }
        await service.attach(link)
        let value = try await service.call("alarms_list", [:])
        XCTAssertEqual(value.objectValue?["source"], "cache")
        XCTAssertEqual(link.calls.filter { $0.tool == "alarms_list" }.count, 1)
    }

    func testBatchPulledBeforeTheCacheIsDeletedIsDropped() async throws {
        let pulls = Recorder<String>()
        let released = Gate()
        let record = MobileRecord(
            kind: .alarm,
            id: "alarm-1",
            key: nil,
            start: nil,
            end: nil,
            payload: Data(#"{"id":"alarm-1","title":"Wake"}"#.utf8)
        )
        let link = FakeLink(syncs: true) { tool, input in
            switch tool {
            case MobileLink.pullTool:
                await pulls.append(input["cache"]?.stringValue ?? "")
                let batch: MobileBatch
                if await pulls.values.count == 1 {
                    await released.wait()
                    batch = MobileBatch(sequence: 1, syncedAt: ["alarms": Date()], records: [record])
                } else {
                    batch = MobileBatch(sequence: 0, syncedAt: [:], records: [])
                }
                return String(decoding: try MobileCoding.encoder.encode(batch), as: UTF8.self)
            case MobileLink.ackTool:
                return #"{"ok":true}"#
            default:
                return "{}"
            }
        }
        await service.attach(link)
        for _ in 0 ..< 100 where await pulls.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await service.cacheID
        try await service.deleteCache()
        let after = await service.cacheID
        await released.open()
        for _ in 0 ..< 100 where await pulls.values.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let ids = await pulls.values
        XCTAssertEqual(ids, [before, after])
        XCTAssertEqual(link.calls.filter { $0.tool == MobileLink.ackTool }.count, 0)
        await service.detach(link)
        let offline = try await service.call("alarms_list", [:])
        XCTAssertEqual(offline.objectValue?["results"]?.arrayValue?.count ?? 0, 0)
    }

    func testLockedPhoneReadsAnswerFromTheCache() async throws {
        let link = FakeLink { _, _ in throw MobileError(MobileTools.lockedMessage) }
        await service.attach(link)
        let value = try await service.call("workouts_fetch", [:])
        XCTAssertEqual(value.objectValue?["source"], "cache")
        XCTAssertTrue(value.objectValue?["note"]?.stringValue?.contains("locked") == true)
    }

    func testCachedFinanceAnswersGiveThePhonesReason() async throws {
        let reason = "This build of iMCP iOS doesn't have the FinanceKit entitlement."
        let link = FakeLink { tool, _ in
            guard tool == MobileTools.statusTool else { throw MobileLinkLost() }
            return #"{"services":{"finance":{"available":false,"note":"\#(reason)"}}}"#
        }
        await service.attach(link)
        _ = try await service.call(MobileTools.statusTool, [:])
        await service.detach(link)
        let value = try await service.call("finance_accounts_list", [:])
        XCTAssertTrue(value.objectValue?["note"]?.stringValue?.contains(reason) == true)
    }

    func testUnpairingTheLastDeviceDeletesTheCache() async throws {
        for id in ["iphone", "ipad"] {
            try pairings.save(
                MobileDevice(id: id, name: id, pairedAt: Date()),
                key: SymmetricKey(size: .bits256)
            )
        }
        let record = MobileRecord(
            kind: .alarm,
            id: "alarm-1",
            key: nil,
            start: nil,
            end: nil,
            payload: Data(#"{"id":"alarm-1"}"#.utf8)
        )
        try await cache.apply(MobileBatch(sequence: 1, syncedAt: ["alarms": Date()], records: [record]))
        try await cache.setPhoneStatus(["services": [:]])
        let before = await service.cacheID

        await service.unpair("ipad")
        let shared = await cache.count(.alarm)
        XCTAssertEqual(shared, 1, "Other paired devices still use the cache.")
        let kept = await service.cacheID
        XCTAssertEqual(kept, before)

        await service.unpair("iphone")
        let remaining = await cache.count(.alarm)
        XCTAssertEqual(remaining, 0)
        let syncedAt = await cache.syncedAt(.alarms)
        XCTAssertNil(syncedAt)
        let status = await cache.phoneStatus()
        XCTAssertNil(status)
        let after = await service.cacheID
        XCTAssertNotEqual(after, before)
    }

    func testPhoneErrorsAreNotRetried() async throws {
        let link = FakeLink { _, _ in throw MobileError("AlarmKit access is off.") }
        await service.attach(link)
        do {
            _ = try await service.call("alarms_cancel", ["id": "8F0C2B8E-6E1A-4D53-9C0B-6A5D1A3E2F10"])
            XCTFail("The phone's error must reach the caller.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("AlarmKit access is off."))
        }
        XCTAssertEqual(link.calls.filter { $0.tool == "alarms_cancel" }.count, 1)
    }
}

final class MobileMemoryPairings: MobilePairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (MobileDevice, SymmetricKey)] = [:]

    func devices() -> [MobileDevice] {
        lock.withLock { entries.values.map(\.0).sorted { $0.id < $1.id } }
    }

    func key(for device: String) -> SymmetricKey? {
        lock.withLock { entries[device]?.1 }
    }

    func save(_ device: MobileDevice, key: SymmetricKey) throws {
        lock.withLock { entries[device.id] = (device, key) }
    }

    func remove(_ device: String) {
        lock.withLock { _ = entries.removeValue(forKey: device) }
    }
}

private final class FakeLink: MobilePeerLink, @unchecked Sendable {
    struct Call {
        let tool: String
        let input: [String: Value]
    }

    let device: MobileDevice
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let syncs: Bool
    private let handler: @Sendable (String, [String: Value]) async throws -> String

    /// A link that answers pulls with an empty batch, unless `syncs` passes them to `handler`.
    init(
        device: String = "fake",
        syncs: Bool = false,
        _ handler: @escaping @Sendable (String, [String: Value]) async throws -> String
    ) {
        self.device = MobileDevice(id: device, name: "Fake iPhone", pairedAt: Date())
        self.syncs = syncs
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recorded } }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        lock.withLock { recorded.append(Call(tool: tool, input: input)) }
        if tool == MobileLink.pullTool, !syncs {
            return String(
                decoding: try MobileCoding.encoder.encode(MobileBatch(sequence: 0, syncedAt: [:], records: [])),
                as: UTF8.self
            )
        }
        return try await handler(tool, input)
    }

    func close() async {}
}

/// A Boolean that a test changes while the service reads it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor Recorder<T: Sendable> {
    var values: [T] = []
    func append(_ value: T) { values.append(value) }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct NoBackend: MobileBackend {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value { .null }
}

/// Two ends of a TLS connection on the loopback interface.
final class MobileChannelTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
    }

    private let keys = [(Data("test".utf8), SymmetricKey(size: .bits256))]

    /// Starts a listener that offers `cipherSuite` and returns its port and connections.
    private func listen(
        cipherSuite: UInt16 = MobileTLS.cipherSuite
    ) async throws -> (NWEndpoint, AsyncStream<NWConnection>) {
        let listener = try NWListener(
            using: MobileTLS.parameters(keys: keys, cipherSuite: cipherSuite),
            on: .any
        )
        self.listener = listener
        let accepted = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
        }
        listener.start(queue: .main)
        var port: NWEndpoint.Port?
        for _ in 0 ..< 100 where port == nil {
            try await Task.sleep(for: .milliseconds(20))
            if case .ready = listener.state { port = listener.port }
        }
        return (.hostPort(host: .ipv4(.loopback), port: try XCTUnwrap(port)), accepted)
    }

    private func pair() async throws -> (MobileChannel, MobileChannel) {
        let (endpoint, accepted) = try await listen()
        let client = MobileChannel(connection: NWConnection(to: endpoint, using: MobileTLS.parameters(keys: keys)))
        async let opened: Void = client.open()
        var iterator = accepted.makeAsyncIterator()
        let connection = await iterator.next()
        let server = MobileChannel(connection: try XCTUnwrap(connection))
        try await server.open()
        try await opened
        return (client, server)
    }

    func testBothSidesNegotiateForwardSecrecy() async throws {
        let (client, server) = try await pair()
        let suites = (await client.cipherSuite, await server.cipherSuite)
        XCTAssertEqual(suites.0, 0xCCAC)
        XCTAssertEqual(suites.1, 0xCCAC)
    }

    func testAPlainPreSharedKeySuiteIsRefused() async throws {
        // A server that prefers a suite without an ephemeral key exchange.
        let (endpoint, accepted) = try await listen(cipherSuite: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))
        let client = MobileChannel(connection: NWConnection(to: endpoint, using: MobileTLS.parameters(keys: keys)))
        let server = Task {
            var iterator = accepted.makeAsyncIterator()
            let connection = await iterator.next()
            connection?.start(queue: .global())
            return connection
        }
        do {
            try await client.open(timeout: .seconds(5))
            XCTFail("A connection without forward secrecy must be refused.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("forward secrecy"), String(describing: error))
        }
        let closed = await client.isClosed
        XCTAssertTrue(closed)
        await server.value?.cancel()
    }

    func testLinesThatArriveBeforeReceiveAreKept() async throws {
        let (client, server) = try await pair()
        try await server.connect()
        try await client.writeLine(Data("one".utf8))
        try await client.writeLine(Data("two".utf8))
        try await Task.sleep(for: .milliseconds(300))
        var lines: [String] = []
        for try await line in await server.receive() {
            lines.append(String(decoding: line, as: UTF8.self))
            if lines.count == 2 { break }
        }
        XCTAssertEqual(lines, ["one", "two"])
    }

    func testAClosedChannelEndsReceivingWithAnError() async throws {
        let (client, server) = try await pair()
        try await server.connect()
        let stream = await server.receive()
        await client.disconnect()
        do {
            for try await _ in stream {}
            XCTFail("A closed connection must end the stream with an error.")
        } catch {}
        do {
            for try await _ in await server.receive() {}
            XCTFail("Receiving again after the close must fail too.")
        } catch {}
    }

    func testReadTimesOutWhenThePeerIsSilent() async throws {
        let (_, server) = try await pair()
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            _ = try await server.read(MobileHello.self, timeout: .milliseconds(300))
            XCTFail("A silent peer must time out.")
        } catch {}
        XCTAssertLessThan(clock.now - begin, .seconds(3))
    }
}

final class MobileKeyExchangeTests: XCTestCase {
    private let code = MobilePairingCode(
        service: "iMCP on Test",
        pairingID: "pairing",
        secret: Data(repeating: 1, count: 32)
    )

    /// Answers a hello the way the Mac does, optionally with the wrong pairing key.
    private func welcome(for hello: MobileHello, secret: Data) throws -> (MobileWelcome, SymmetricKey) {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let pairingKey = MobileLink.pairingKey(secret: secret)
        let phone = try XCTUnwrap(hello.exchange)
        let key = try MobileKeyExchange.deviceKey(
            privateKey: mac,
            peer: phone,
            pairingKey: pairingKey,
            device: hello.device,
            phone: phone,
            mac: mac.publicKey.rawRepresentation
        )
        let welcome = MobileWelcome(
            ok: true,
            mac: code.service,
            exchange: mac.publicKey.rawRepresentation,
            proof: MobileKeyExchange.welcomeProof(
                pairingKey: pairingKey,
                pairingID: code.pairingID,
                device: hello.device,
                phone: phone,
                mac: mac.publicKey.rawRepresentation
            )
        )
        return (welcome, key)
    }

    func testBothSidesDeriveTheSameKey() throws {
        let credentials = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        let (welcome, macKey) = try welcome(for: credentials.hello, secret: code.secret)
        let phoneKey = try credentials.deviceKey(from: welcome)
        XCTAssertEqual(phoneKey.map { $0.withUnsafeBytes { Data($0) } }, macKey.withUnsafeBytes { Data($0) })
    }

    func testPhoneRejectsAWelcomeProvedWithAnotherKey() throws {
        let credentials = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        let (welcome, _) = try welcome(for: credentials.hello, secret: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try credentials.deviceKey(from: welcome))
    }

    func testPhoneRejectsAWelcomeWithoutAnExchange() throws {
        let credentials = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        XCTAssertThrowsError(try credentials.deviceKey(from: MobileWelcome(ok: true, mac: code.service)))
    }

    func testEachPairingDerivesADifferentKey() throws {
        let first = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        let second = MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone")
        let (_, a) = try welcome(for: first.hello, secret: code.secret)
        let (_, b) = try welcome(for: second.hello, secret: code.secret)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }
}
