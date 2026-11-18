import CryptoKit
import Foundation
import JSONSchema
import MCP
import Network
import XCTest

final class MobileTransportTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
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

    // MARK: - Routes

    func testRoutesGiveAnEarlierRouteALimitedBudgetAndTheLastTheRest() async throws {
        let candidates: [MobileTransportCandidate] = [
            .bonjour(service: "Mac"),
            .tailscaleVPN(host: "100.64.0.5", port: 4628),
            .cloudflare(url: URL(string: "wss://tunnel.example.com/mobile")!),
        ]
        let budgets = BudgetLog()
        let result = try await MobileRoutes.firstReachable(candidates, within: .seconds(30), budget: .seconds(6)) {
            candidate,
            budget in
            await budgets.record(candidate.mode, budget)
            if candidate.mode != .cloudflare { throw MobileError("No answer.") }
            return "connected"
        }
        XCTAssertEqual(result, "connected")
        let recorded = await budgets.entries
        XCTAssertEqual(recorded.map(\.0), [.localOnly, .tailscaleVPN, .cloudflare])
        XCTAssertEqual(recorded[0].1, .seconds(6))
        XCTAssertEqual(recorded[1].1, .seconds(6))
        XCTAssertGreaterThan(recorded[2].1, .seconds(20), "The last route gets what the others left.")
    }

    func testRoutesStopAtTheFirstThatConnectsAndNameEveryFailure() async throws {
        let candidates: [MobileTransportCandidate] = [
            .bonjour(service: "Mac"), .tailscaleVPN(host: "100.64.0.5", port: 4628),
        ]
        let tried = BudgetLog()
        let first = try await MobileRoutes.firstReachable(candidates, within: .seconds(10)) { candidate, budget in
            await tried.record(candidate.mode, budget)
            return candidate.mode
        }
        XCTAssertEqual(first, .localOnly)
        let triedCount = await tried.entries.count
        XCTAssertEqual(triedCount, 1)

        do {
            _ = try await MobileRoutes.firstReachable(candidates, within: .seconds(10)) {
                (candidate, _) -> Int in throw MobileError("refused")
            }
            XCTFail("Every route failed, so the dial must fail.")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Local Network: refused"), message)
            XCTAssertTrue(message.contains("Tailscale VPN: refused"), message)
        }
    }

    func testRoutesDoNotSwallowCancellation() async {
        let task = Task {
            try await MobileRoutes.firstReachable([.bonjour(service: "Mac")], within: .seconds(10)) {
                (_, _) -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled dial must not succeed.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error).")
        }
    }

    func testModesWithoutAnEndpointSayWhyTheyAreUnavailable() {
        XCTAssertNil(MobileTransportMode.automatic.unavailableReason(hasCandidates: false))
        XCTAssertNil(MobileTransportMode.localOnly.unavailableReason(hasCandidates: false))
        XCTAssertNil(MobileTransportMode.tailscaleFunnel.unavailableReason(hasCandidates: true))
        XCTAssertEqual(
            MobileTransportMode.tailscaleFunnel.unavailableReason(hasCandidates: false),
            "Tailscale Funnel isn't available: this Mac hasn't offered a Funnel address."
        )
        XCTAssertNotNil(MobileTransportMode.cloudflare.unavailableReason(hasCandidates: false))
        XCTAssertNotNil(MobileTransportMode.tailscaleVPN.unavailableReason(hasCandidates: false))
    }

    // MARK: - Mac endpoints

    func testTailnetAddressesAreTheCGNATRange() {
        XCTAssertTrue(MobileTailnet.isTailnetAddress([100, 64, 0, 1]))
        XCTAssertTrue(MobileTailnet.isTailnetAddress([100, 127, 255, 254]))
        XCTAssertFalse(MobileTailnet.isTailnetAddress([100, 63, 0, 1]))
        XCTAssertFalse(MobileTailnet.isTailnetAddress([100, 128, 0, 1]))
        XCTAssertFalse(MobileTailnet.isTailnetAddress([192, 168, 1, 5]))
        XCTAssertFalse(MobileTailnet.isTailnetAddress([100, 64, 0]))
    }

    func testMacAdvertisesOnlyWhatTheModeAllows() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            MobileService.transportModeKey, MobileService.tailscaleVPNEnabledKey,
            MobileService.tailscaleHostOverrideKey, MobileService.cloudflareEnabledKey,
            MobileService.cloudflareURLKey,
        ]
        defer { keys.forEach(defaults.removeObject(forKey:)) }
        keys.forEach(defaults.removeObject(forKey:))
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: MobileMemoryPairings(),
            advertise: false,
            pollInterval: .seconds(60)
        )
        await service.updateRemoteEndpoints(
            tailnetHost: "mac.tailnet.ts.net",
            funnelURL: "https://mac.tailnet.ts.net"
        )
        defaults.set("imcp.example.com", forKey: MobileService.cloudflareURLKey)
        defaults.set(true, forKey: MobileService.cloudflareEnabledKey)

        var endpoints = await service.currentEndpoints
        XCTAssertEqual(endpoints.tailnetHost, "mac.tailnet.ts.net")
        XCTAssertEqual(endpoints.funnelURL, "wss://mac.tailnet.ts.net/mobile")
        XCTAssertEqual(endpoints.cloudflareURL, "wss://imcp.example.com/mobile")

        defaults.set("100.64.1.2", forKey: MobileService.tailscaleHostOverrideKey)
        endpoints = await service.currentEndpoints
        XCTAssertEqual(endpoints.tailnetHost, "100.64.1.2", "The typed host wins over the advertised one.")

        defaults.set(false, forKey: MobileService.tailscaleVPNEnabledKey)
        endpoints = await service.currentEndpoints
        XCTAssertNil(endpoints.tailnetHost)
        XCTAssertNil(endpoints.tailnetPort)

        defaults.set(MobileTransportMode.localOnly.rawValue, forKey: MobileService.transportModeKey)
        endpoints = await service.currentEndpoints
        XCTAssertEqual(endpoints, MobileRemoteEndpoints(), "Local only advertises nothing else.")
    }

    func testPairingCodeCarriesTheListenerPortWhenATailscaleHostIsSet() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: MobileService.transportModeKey)
        defaults.removeObject(forKey: MobileService.tailscaleVPNEnabledKey)
        defaults.set("100.64.9.9", forKey: MobileService.tailscaleHostOverrideKey)
        defer { defaults.removeObject(forKey: MobileService.tailscaleHostOverrideKey) }
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: MobileMemoryPairings(),
            advertise: false,
            pollInterval: .seconds(60)
        )
        let code = try await service.beginPairing()
        let port = await service.listeningPort
        XCTAssertEqual(code.tailnetHost, "100.64.9.9")
        XCTAssertNotNil(port)
        XCTAssertEqual(code.tailnetPort, port)
        await service.stop()
    }
}

private actor BudgetLog {
    private(set) var entries: [(MobileTransportMode, Duration)] = []
    func record(_ mode: MobileTransportMode, _ budget: Duration) { entries.append((mode, budget)) }
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
