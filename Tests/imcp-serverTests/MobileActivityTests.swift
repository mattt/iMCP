import CryptoKit
import Foundation
import JSONSchema
import Network
import XCTest

final class MobileActivityTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - MobileActivityStore

    func testActivityStoreRingBufferAndPersistence() async throws {
        let url = directory.appendingPathComponent("activity.json")
        let store = try MobileActivityStore(url: url, maxEvents: 3)

        for index in 1 ... 5 {
            await store.record(
                MobileActivityEvent(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                    clientName: "Claude",
                    serviceName: "Calendar",
                    toolName: "events_fetch_\(index)",
                    isWrite: index % 2 == 0,
                    outcome: .succeeded,
                    durationMs: index * 10
                )
            )
        }

        let events = await store.allEvents()
        XCTAssertEqual(events.map(\.toolName), ["events_fetch_3", "events_fetch_4", "events_fetch_5"])
        XCTAssertEqual(events.map(\.sequence), [3, 4, 5])

        let reloaded = try MobileActivityStore(url: url, maxEvents: 3)
        let reloadedEvents = await reloaded.allEvents()
        XCTAssertEqual(reloadedEvents, events)

        let next = await reloaded.record(
            MobileActivityEvent(
                clientName: "Cursor",
                serviceName: "Notes",
                toolName: "notes_create",
                isWrite: true,
                outcome: .denied,
                detail: "Writes disabled"
            )
        )
        XCTAssertEqual(next.sequence, 6)
    }

    func testActivityStorePerDeviceAcknowledgementAndReset() async throws {
        let url = directory.appendingPathComponent("activity.json")
        let store = try MobileActivityStore(url: url, maxEvents: 10)

        await store.record(
            MobileActivityEvent(
                clientName: "Claude",
                serviceName: "Contacts",
                toolName: "contacts_search",
                isWrite: false,
                outcome: .succeeded
            )
        )
        await store.record(
            MobileActivityEvent(
                clientName: "Claude",
                serviceName: "Messages",
                toolName: "messages_send",
                isWrite: true,
                outcome: .denied,
                detail: "Declined"
            )
        )

        let initialPending = await store.pendingEvents(for: "phone-1")
        XCTAssertEqual(initialPending.map(\.sequence), [1, 2])

        await store.acknowledge(1, for: "phone-1")
        let afterFirstAck = await store.pendingEvents(for: "phone-1")
        XCTAssertEqual(afterFirstAck.map(\.sequence), [2])

        let otherDevicePending = await store.pendingEvents(for: "phone-2")
        XCTAssertEqual(otherDevicePending.map(\.sequence), [1, 2])

        await store.acknowledge(2, for: "phone-1")
        let drained = await store.pendingEvents(for: "phone-1")
        XCTAssertTrue(drained.isEmpty)

        await store.resetAcknowledgement(for: "phone-1")
        let resetPending = await store.pendingEvents(for: "phone-1")
        XCTAssertEqual(resetPending.map(\.sequence), [1, 2])
    }

    func testMobileServiceSyncsActivityToConnectedPhone() async throws {
        let activityURL = directory.appendingPathComponent("activity.json")
        let activityStore = try MobileActivityStore(url: activityURL)
        let pairings = MobileMemoryPairings()
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            activityStore: activityStore,
            pairings: pairings,
            reconnectGrace: .milliseconds(500),
            advertise: false,
            pollInterval: .seconds(60)
        )

        let syncedBatches = ActivityRecorder()
        let tools = [
            Tool(
                name: MobileActivityLink.syncTool,
                description: "Sync activity",
                inputSchema: .object(properties: [:], additionalProperties: true),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ) { input in
                let request = try MobileCoding.decoder.decode(
                    MobileActivitySyncRequest.self,
                    from: JSONEncoder().encode(input)
                )
                await syncedBatches.append(request.events)
                let maxSeq = request.events.map(\.sequence).max() ?? 0
                let response = MobileActivitySyncResponse(ackedSequence: maxSeq)
                return try JSONDecoder().decode(Value.self, from: MobileCoding.encoder.encode(response))
            }
        ]

        let code = try await service.beginPairing()
        let listeningPort = await service.listeningPort
        let port = try XCTUnwrap(listeningPort)
        let session = try await MobileDialer.connect(
            to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
            with: MobileDialer.pairing(code, device: "phone-1", name: "Test iPhone"),
            timeout: .seconds(5)
        )
        let peerTask = Task { try await MobilePeer.serve(session.channel, tools: tools, version: "test") }
        defer {
            peerTask.cancel()
        }

        for _ in 0 ..< 100 where await !service.isConnected {
            try await Task.sleep(for: .milliseconds(25))
        }
        let connected = await service.isConnected
        XCTAssertTrue(connected)

        await service.recordActivity(
            MobileActivityEvent(
                clientName: "Claude Desktop",
                serviceName: "Notes",
                toolName: "notes_search",
                isWrite: false,
                outcome: .succeeded,
                durationMs: 24
            )
        )

        for _ in 0 ..< 100 where await syncedBatches.all.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }

        let received = await syncedBatches.all.flatMap { $0 }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.clientName, "Claude Desktop")
        XCTAssertEqual(received.first?.serviceName, "Notes")
        XCTAssertEqual(received.first?.toolName, "notes_search")
        XCTAssertEqual(received.first?.isWrite, false)
        XCTAssertEqual(received.first?.outcome, .succeeded)
        XCTAssertEqual(received.first?.durationMs, 24)
        let acked = await activityStore.ackedSequence(for: "phone-1")
        XCTAssertEqual(acked, 1)

        await service.stop()
        await session.channel.disconnect()
    }

    func testActivityPersistedBeforeARelaunchReachesThePhoneWithoutNewToolCalls() async throws {
        let activityURL = directory.appendingPathComponent("activity.json")
        let before = try MobileActivityStore(url: activityURL)
        await before.record(
            MobileActivityEvent(
                clientName: "Claude Desktop",
                serviceName: "Notes",
                toolName: "notes_search",
                isWrite: false,
                outcome: .succeeded,
                durationMs: 5
            )
        )
        // A relaunched Mac has no store in memory; it opens the one on disk.
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: MobileMemoryPairings(),
            activityStoreOpener: { try MobileActivityStore(url: activityURL) },
            advertise: false,
            pollInterval: .seconds(60)
        )
        let link = RecordingActivityLink()
        await service.attach(link)
        for _ in 0 ..< 100 where link.sent.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(link.sent.count, 1)
        await service.stop()
    }
}

private actor ActivityRecorder {
    private(set) var all: [[MobileActivityEvent]] = []
    func append(_ batch: [MobileActivityEvent]) { all.append(batch) }
}

private final class RecordingActivityLink: MobilePeerLink, @unchecked Sendable {
    let device = MobileDevice(id: "phone-1", name: "Test iPhone", pairedAt: Date())
    private let lock = NSLock()
    private var events: [MobileActivityEvent] = []

    var sent: [MobileActivityEvent] { lock.withLock { events } }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        switch tool {
        case MobileActivityLink.syncTool:
            let request = try MobileCoding.decoder.decode(
                MobileActivitySyncRequest.self,
                from: JSONEncoder().encode(input)
            )
            lock.withLock { events += request.events }
            let acked = request.events.map(\.sequence).max() ?? 0
            return String(
                decoding: try MobileCoding.encoder.encode(MobileActivitySyncResponse(ackedSequence: acked)),
                as: UTF8.self
            )
        case MobileLink.pullTool:
            return String(
                decoding: try MobileCoding.encoder.encode(MobileBatch(sequence: 0, syncedAt: [:], records: [])),
                as: UTF8.self
            )
        default:
            return "{}"
        }
    }

    func close() async {}
}
