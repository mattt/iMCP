import CryptoKit
import JSONSchema
import Network
import XCTest

final class CompanionLinkTests: XCTestCase {
    private var directory: URL!
    private var pairings: CompanionMemoryPairings!
    private var service: CompanionService!
    private var port: UInt16 = 0
    private var phoneTasks: [Task<Void, Error>] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pairings = CompanionMemoryPairings()
        service = CompanionService(
            cache: try CompanionCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: pairings,
            reconnectGrace: .milliseconds(500),
            advertise: false,
            pollInterval: .seconds(60)
        )
        port = try await service.startListening()
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
        _ credentials: CompanionDialer.Credentials,
        tools: [Tool] = []
    ) async throws -> CompanionWelcome {
        let (channel, welcome) = try await CompanionDialer.connect(to: endpoint, with: credentials)
        phoneTasks.append(Task { try await CompanionPeer.serve(channel, tools: tools, version: "test") })
        return welcome
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
        XCTAssertEqual(CompanionPairingCode(url: code.url), code)
        let welcome = try await connectPhone(
            CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"),
            tools: [phoneTool("alarms_list") { _ in ["source": "live", "results": []] }]
        )
        XCTAssertTrue(welcome.ok)
        XCTAssertEqual(welcome.deviceKey?.count, 32)
        XCTAssertEqual(pairings.devices().map(\.id), ["phone-1"])
        try await waitUntilConnected()

        let value = try await service.call("alarms_list", [:])
        XCTAssertEqual(value.objectValue?["source"], "live")
        let status = try await service.call("companion_status", [:])
        XCTAssertEqual(status.objectValue?["connected"], true)
        XCTAssertEqual(status.objectValue?["device"], "Test iPhone")
    }

    func testPairingCodeWorksOnce() async throws {
        let code = try await service.beginPairing()
        try await connectPhone(CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        do {
            try await connectPhone(CompanionDialer.pairing(code, device: "phone-2", name: "Other iPhone"))
            XCTFail("A pairing code must not work twice.")
        } catch {}
        XCTAssertEqual(pairings.devices().map(\.id), ["phone-1"])
    }

    func testPairedDeviceReconnectsWithItsKey() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = SymmetricKey(data: try XCTUnwrap(welcome.deviceKey))
        try await waitUntilConnected()
        await service.disconnect()
        try await waitUntilConnected(false)
        // With a pairing code on screen, the listener holds two keys
        // and must choose the device's key by its identity.
        _ = try await service.beginPairing()

        let again = try await connectPhone(CompanionDialer.paired(device: "phone-1", name: "Test iPhone", key: key))
        XCTAssertTrue(again.ok)
        XCTAssertNil(again.deviceKey)
        try await waitUntilConnected()
    }

    func testWrongPairingSecretIsRejected() async throws {
        let code = try await service.beginPairing()
        var wrong = code
        wrong.secret = Data(repeating: 7, count: 32)
        do {
            try await connectPhone(CompanionDialer.pairing(wrong, device: "phone-1", name: "Intruder"))
            XCTFail("A wrong pairing secret must be rejected.")
        } catch {}
        XCTAssertTrue(pairings.devices().isEmpty)
        let connected = await service.isConnected
        XCTAssertFalse(connected)
    }

    func testUnknownDeviceKeyIsRejected() async throws {
        do {
            try await connectPhone(
                CompanionDialer.paired(device: "phone-9", name: "Stranger", key: SymmetricKey(size: .bits256))
            )
            XCTFail("An unpaired device must be rejected.")
        } catch {}
    }

    func testMacCanRevokeAPairing() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = SymmetricKey(data: try XCTUnwrap(welcome.deviceKey))
        try await waitUntilConnected()
        await service.unpair("phone-1")
        try await waitUntilConnected(false)
        XCTAssertTrue(pairings.devices().isEmpty)
        do {
            try await connectPhone(CompanionDialer.paired(device: "phone-1", name: "Test iPhone", key: key))
            XCTFail("A revoked device must be rejected.")
        } catch {}
    }

    func testPhoneCanRevokeItsPairing() async throws {
        let code = try await service.beginPairing()
        let welcome = try await connectPhone(CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"))
        let key = SymmetricKey(data: try XCTUnwrap(welcome.deviceKey))
        let goodbye = try await connectPhone(
            CompanionDialer.paired(device: "phone-1", name: "Test iPhone", key: key, revoke: true)
        )
        XCTAssertTrue(goodbye.ok)
        XCTAssertTrue(pairings.devices().isEmpty)
    }

    func testSyncPullAppliesBatchesAndAcknowledgesThem() async throws {
        let acknowledged = Recorder<Int>()
        let cacheIDs = Recorder<String>()
        let sent = Recorder<Bool>()
        let record = CompanionRecord(
            kind: .alarm,
            id: "alarm-1",
            key: nil,
            start: nil,
            end: nil,
            payload: Data(#"{"id":"alarm-1","title":"Wake"}"#.utf8)
        )
        let syncedAt = Date()
        let tools = [
            phoneTool(CompanionLink.pullTool) { input in
                if let id = input["cache"]?.stringValue { await cacheIDs.append(id) }
                if await sent.values.isEmpty {
                    await sent.append(true)
                    let batch = CompanionBatch(
                        sequence: 7,
                        syncedAt: ["alarms": syncedAt],
                        records: [record],
                        replacing: [.alarm]
                    )
                    return try JSONDecoder().decode(Value.self, from: CompanionCoding.encoder.encode(batch))
                }
                return try JSONDecoder().decode(
                    Value.self,
                    from: CompanionCoding.encoder.encode(CompanionBatch(sequence: 0, syncedAt: [:], records: []))
                )
            },
            phoneTool(CompanionLink.ackTool) { input in
                await acknowledged.append(input["sequence"]?.intValue ?? -1)
                return ["ok": true]
            },
        ]
        let code = try await service.beginPairing()
        try await connectPhone(CompanionDialer.pairing(code, device: "phone-1", name: "Test iPhone"), tools: tools)
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
            CompanionTools.all(backend: NoBackend()).first { $0.name == name }?.inputSchema ?? .object()
        return Tool(
            name: name,
            description: name,
            inputSchema: schema,
            annotations: .init(readOnlyHint: true),
            implementation: body
        )
    }
}

final class CompanionRetryTests: XCTestCase {
    private var directory: URL!
    private var service: CompanionService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = CompanionService(
            cache: try CompanionCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: CompanionMemoryPairings(),
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
        let first = FakeLink { _, _ in throw CompanionLinkLost() }
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

    func testLostWriteWithoutReconnectReportsTheIdentifier() async throws {
        let link = FakeLink { _, _ in throw CompanionLinkLost() }
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
        let link = FakeLink { _, _ in throw CompanionLinkLost() }
        await service.attach(link)
        let value = try await service.call("alarms_list", [:])
        XCTAssertEqual(value.objectValue?["source"], "cache")
        XCTAssertEqual(link.calls.filter { $0.tool == "alarms_list" }.count, 1)
    }

    func testPhoneErrorsAreNotRetried() async throws {
        let link = FakeLink { _, _ in throw CompanionError("AlarmKit access is off.") }
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

final class CompanionMemoryPairings: CompanionPairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (CompanionDevice, SymmetricKey)] = [:]

    func devices() -> [CompanionDevice] {
        lock.withLock { entries.values.map(\.0).sorted { $0.id < $1.id } }
    }

    func key(for device: String) -> SymmetricKey? {
        lock.withLock { entries[device]?.1 }
    }

    func save(_ device: CompanionDevice, key: SymmetricKey) throws {
        lock.withLock { entries[device.id] = (device, key) }
    }

    func remove(_ device: String) {
        lock.withLock { _ = entries.removeValue(forKey: device) }
    }
}

private final class FakeLink: CompanionPeerLink, @unchecked Sendable {
    struct Call {
        let tool: String
        let input: [String: Value]
    }

    let device = CompanionDevice(id: "fake", name: "Fake iPhone", pairedAt: Date())
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (String, [String: Value]) async throws -> String

    init(_ handler: @escaping @Sendable (String, [String: Value]) async throws -> String) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recorded } }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        lock.withLock { recorded.append(Call(tool: tool, input: input)) }
        if tool == CompanionLink.pullTool {
            return String(
                decoding: try CompanionCoding.encoder.encode(CompanionBatch(sequence: 0, syncedAt: [:], records: [])),
                as: UTF8.self
            )
        }
        return try await handler(tool, input)
    }

    func close() async {}
}

private actor Recorder<T: Sendable> {
    var values: [T] = []
    func append(_ value: T) { values.append(value) }
}

private struct NoBackend: CompanionBackend {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value { .null }
}
