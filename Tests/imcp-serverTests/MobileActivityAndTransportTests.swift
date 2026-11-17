import CryptoKit
import Foundation
import JSONSchema
import Network
import XCTest

final class MobileActivityAndTransportTests: XCTestCase {
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

    // MARK: - MobilePairingCode Multi-Transport

    func testPairingCodeRoundTripsMultiTransportEndpoints() throws {
        let secret = Data(repeating: 0xAB, count: 32)
        let code = MobilePairingCode(
            service: "iMCP on Mac",
            pairingID: "pair-123",
            secret: secret,
            tailnetHost: "mac-imcp.tailnet.ts.net",
            tailnetPort: 4628,
            funnelURL: "https://mac-imcp.tailnet.ts.net",
            cloudflareURL: "imcp.example.com"
        )

        XCTAssertEqual(code.tailnetHost, "mac-imcp.tailnet.ts.net")
        XCTAssertEqual(code.tailnetPort, 4628)
        XCTAssertEqual(code.funnelURL, "wss://mac-imcp.tailnet.ts.net/mobile")
        XCTAssertEqual(code.cloudflareURL, "wss://imcp.example.com/mobile")

        let decoded = try XCTUnwrap(MobilePairingCode(url: code.url))
        XCTAssertEqual(decoded, code)
    }

    func testPairingCodeRemainsCompatibleWithoutRemoteEndpoints() throws {
        let secret = Data(repeating: 0xCD, count: 32)
        let code = MobilePairingCode(service: "iMCP on Mac", pairingID: "pair-456", secret: secret)
        let decoded = try XCTUnwrap(MobilePairingCode(url: code.url))
        XCTAssertEqual(decoded, code)
        XCTAssertNil(decoded.tailnetHost)
        XCTAssertNil(decoded.tailnetPort)
        XCTAssertNil(decoded.funnelURL)
        XCTAssertNil(decoded.cloudflareURL)
    }

    // MARK: - MobileTransportMode Selection

    func testTransportModeCandidateSelection() {
        let allConfigured: (String, String?, UInt16?, String?, String?) = (
            "iMCP on Mac",
            "100.64.0.5",
            nil,
            "wss://mac.ts.net/mobile",
            "wss://tunnel.example.com/mobile"
        )

        XCTAssertEqual(
            MobileTransportMode.automatic.candidates(
                service: allConfigured.0,
                tailnetHost: allConfigured.1,
                tailnetPort: allConfigured.2,
                funnelURL: allConfigured.3,
                cloudflareURL: allConfigured.4
            ),
            [
                .bonjour(service: "iMCP on Mac"),
                .tailscaleVPN(host: "100.64.0.5", port: MobileLink.defaultRemotePort),
                .tailscaleFunnel(url: URL(string: "wss://mac.ts.net/mobile")!),
                .cloudflare(url: URL(string: "wss://tunnel.example.com/mobile")!),
            ]
        )

        XCTAssertEqual(
            MobileTransportMode.localOnly.candidates(
                service: allConfigured.0,
                tailnetHost: allConfigured.1,
                tailnetPort: allConfigured.2,
                funnelURL: allConfigured.3,
                cloudflareURL: allConfigured.4
            ),
            [.bonjour(service: "iMCP on Mac")]
        )

        XCTAssertEqual(
            MobileTransportMode.tailscaleVPN.candidates(
                service: "iMCP on Mac",
                tailnetHost: "mac.ts.net",
                tailnetPort: 4999,
                funnelURL: nil,
                cloudflareURL: nil
            ),
            [.tailscaleVPN(host: "mac.ts.net", port: 4999)]
        )

        XCTAssertTrue(
            MobileTransportMode.tailscaleVPN.candidates(
                service: "iMCP on Mac",
                tailnetHost: "   ",
                tailnetPort: nil,
                funnelURL: nil,
                cloudflareURL: nil
            ).isEmpty
        )

        XCTAssertEqual(
            MobileTransportMode.tailscaleFunnel.candidates(
                service: "iMCP on Mac",
                tailnetHost: nil,
                tailnetPort: nil,
                funnelURL: "https://mac.ts.net",
                cloudflareURL: nil
            ),
            [.tailscaleFunnel(url: URL(string: "wss://mac.ts.net/mobile")!)]
        )

        XCTAssertEqual(
            MobileTransportMode.cloudflare.candidates(
                service: "iMCP on Mac",
                tailnetHost: nil,
                tailnetPort: nil,
                funnelURL: nil,
                cloudflareURL: "wss://cf.example.com/mobile"
            ),
            [.cloudflare(url: URL(string: "wss://cf.example.com/mobile")!)]
        )
    }

    // MARK: - WebSocket + AEAD End-to-End

    func testWebSocketEncryptedChannelPairingAndReconnect() async throws {
        let pairings = MobileMemoryPairings()
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: pairings,
            reconnectGrace: .milliseconds(500),
            advertise: false,
            pollInterval: .seconds(60)
        )

        let code = try await service.beginPairing()
        try await service.startWebSocketListener(port: 0)
        let maybeWSPort = await service.webSocketPort
        let wsPort = try XCTUnwrap(maybeWSPort)
        let wsURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(wsPort)/mobile"))
        let tools = [
            Tool(
                name: "alarms_list",
                description: "List alarms",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ) { _ in
                ["source": "live", "transport": "websocket"]
            }
        ]

        // 1. Pair over WebSocket + AEAD.
        let pairSession = try await MobileWebSocketDialer.connect(
            to: wsURL,
            with: MobileWebSocketDialer.pairing(code, device: "phone-ws", name: "WS iPhone"),
            timeout: .seconds(5)
        )
        let deviceKey = try XCTUnwrap(pairSession.deviceKey)
        let firstPeer = Task { try await MobilePeer.serve(pairSession.channel, tools: tools, version: "test") }
        for _ in 0 ..< 100 where await !service.isConnected {
            try await Task.sleep(for: .milliseconds(25))
        }
        let connectedTransport = await service.connectedTransport
        XCTAssertEqual(connectedTransport, .cloudflare)

        let liveResult = try await service.call("alarms_list", [:])
        XCTAssertEqual(liveResult.objectValue?["transport"], "websocket")

        firstPeer.cancel()
        await pairSession.channel.disconnect()
        for _ in 0 ..< 100 where await service.isConnected {
            try await Task.sleep(for: .milliseconds(25))
        }

        // 2. Reconnect with derived device key over WebSocket + AEAD.
        let reconnectSession = try await MobileWebSocketDialer.connect(
            to: wsURL,
            with: MobileWebSocketDialer.paired(device: "phone-ws", name: "WS iPhone", key: deviceKey),
            timeout: .seconds(5)
        )
        let secondPeer = Task { try await MobilePeer.serve(reconnectSession.channel, tools: tools, version: "test") }
        for _ in 0 ..< 100 where await !service.isConnected {
            try await Task.sleep(for: .milliseconds(25))
        }
        let secondResult = try await service.call("alarms_list", [:])
        XCTAssertEqual(secondResult.objectValue?["source"], "live")

        secondPeer.cancel()
        await reconnectSession.channel.disconnect()
        await service.stop()
    }

    func testEncryptedChannelRejectsTamperingAndReplay() async throws {
        let psk = SymmetricKey(size: .bits256)
        let phonePriv = Curve25519.KeyAgreement.PrivateKey()
        let macPriv = Curve25519.KeyAgreement.PrivateKey()
        let phonePub = phonePriv.publicKey.rawRepresentation
        let macPub = macPriv.publicKey.rawRepresentation

        let phoneKeys = try MobileKeyExchange.sessionKeys(
            privateKey: phonePriv,
            peer: macPub,
            psk: psk,
            device: "d1",
            phone: phonePub,
            mac: macPub,
            role: .phone
        )
        let macKeys = try MobileKeyExchange.sessionKeys(
            privateKey: macPriv,
            peer: phonePub,
            psk: psk,
            device: "d1",
            phone: phonePub,
            mac: macPub,
            role: .mac
        )

        // Capture a valid encrypted frame sent from phone -> mac.
        let phoneWire = InMemoryFrameWire()
        let phoneChannel = MobileEncryptedChannel(
            wire: phoneWire,
            sendKey: phoneKeys.send,
            receiveKey: phoneKeys.receive,
            role: .phone
        )
        try await phoneChannel.send(Data("hello-1".utf8))
        try await phoneChannel.send(Data("hello-2".utf8))
        let sentFrames = await phoneWire.sentFrames
        XCTAssertEqual(sentFrames.count, 2)

        // Valid order succeeds.
        let macWire1 = InMemoryFrameWire(incoming: sentFrames)
        let macChannel1 = MobileEncryptedChannel(
            wire: macWire1,
            sendKey: macKeys.send,
            receiveKey: macKeys.receive,
            role: .mac
        )
        try await macChannel1.connect()
        let stream1 = await macChannel1.receive()
        var received: [Data] = []
        do {
            for try await msg in stream1 {
                received.append(msg)
            }
        } catch {}
        XCTAssertEqual(received, [Data("hello-1".utf8), Data("hello-2".utf8)])

        // Replaying frame 0 twice is rejected and closes channel.
        let replayWire = InMemoryFrameWire(incoming: [sentFrames[0], sentFrames[0]])
        let replayChannel = MobileEncryptedChannel(
            wire: replayWire,
            sendKey: macKeys.send,
            receiveKey: macKeys.receive,
            role: .mac
        )
        try await replayChannel.connect()
        let replayStream = await replayChannel.receive()
        var replayReceived: [Data] = []
        do {
            for try await msg in replayStream {
                replayReceived.append(msg)
            }
        } catch {}
        XCTAssertEqual(replayReceived, [Data("hello-1".utf8)])
        let replayClosed = await replayChannel.isClosed
        XCTAssertTrue(replayClosed)

        // Tampering with ciphertext is rejected.
        var tampered = sentFrames[0]
        tampered[tampered.count - 1] ^= 0xFF
        let tamperWire = InMemoryFrameWire(incoming: [tampered])
        let tamperChannel = MobileEncryptedChannel(
            wire: tamperWire,
            sendKey: macKeys.send,
            receiveKey: macKeys.receive,
            role: .mac
        )
        try await tamperChannel.connect()
        let tamperStream = await tamperChannel.receive()
        var tamperReceived: [Data] = []
        do {
            for try await msg in tamperStream {
                tamperReceived.append(msg)
            }
        } catch {}
        XCTAssertTrue(tamperReceived.isEmpty)
        let tamperClosed = await tamperChannel.isClosed
        XCTAssertTrue(tamperClosed)
    }

    func testWebSocketHandshakeAcceptKeyMatchesRFC6455Vector() {
        // RFC 6455 Section 1.3 example vector
        let accept = MobileWebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertTrue(
            MobileWebSocketHandshake.isUpgradeRequest(
                method: "GET",
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                ]
            )
        )
        XCTAssertFalse(
            MobileWebSocketHandshake.isUpgradeRequest(
                method: "POST",
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                ]
            )
        )
    }
}

private actor ActivityRecorder {
    private(set) var all: [[MobileActivityEvent]] = []
    func append(_ batch: [MobileActivityEvent]) { all.append(batch) }
}

private actor InMemoryFrameWire: MobileFrameWire {
    private(set) var sentFrames: [Data] = []
    private var incoming: [Data]

    init(incoming: [Data] = []) {
        self.incoming = incoming
    }

    func sendFrame(_ data: Data) async throws {
        sentFrames.append(data)
    }

    func receiveFrame() async throws -> Data? {
        guard !incoming.isEmpty else { return nil }
        return incoming.removeFirst()
    }

    func close() async {}
}
