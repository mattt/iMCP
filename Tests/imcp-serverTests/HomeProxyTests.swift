import AppKit
import CryptoKit
import MCP
import Network
import XCTest
import dnssd
import os

final class HomeProxyTests: XCTestCase {
    @MainActor
    func testLiveLaunchAndRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["IMCP_HELPER_PATH"], let code = environment["IMCP_HELPER_CODE"] else {
            throw XCTSkip(
                "Set IMCP_HELPER_PATH and IMCP_HELPER_CODE (the code in the helper's window) to run the signed helper integration test."
            )
        }
        let backend = HomeService(
            helperURL: URL(fileURLWithPath: path),
            keyStore: MemoryKeyStore(),
            pendingKeyStore: MemoryKeyStore()
        )
        let initial = await backend.isActivated
        XCTAssertFalse(initial)
        try await backend.pair(code: code)
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

final class HomeHelperPairingTests: XCTestCase {
    func testGeneratesCodesOfTwoGroupsOfFour() throws {
        let code = try HomeHelperPairing.generateCode()
        XCTAssertEqual(code.split(separator: "-").map(\.count), [4, 4])
        XCTAssertEqual(HomeHelperPairing.normalize(code)?.count, 8)
        XCTAssertNotEqual(code, try HomeHelperPairing.generateCode())
    }

    func testNormalizesSeparatorsCaseAndCrockfordSubstitutes() {
        XCTAssertEqual(HomeHelperPairing.normalize("abcd-efgh"), "ABCDEFGH")
        XCTAssertEqual(HomeHelperPairing.normalize("ABCD EFGH"), "ABCDEFGH")
        XCTAssertEqual(HomeHelperPairing.normalize("ABCDEFGH"), "ABCDEFGH")
        XCTAssertEqual(HomeHelperPairing.normalize("oOiI-lLAB"), "001111AB")
        XCTAssertNil(HomeHelperPairing.normalize("ABCD-EFGU"))
        XCTAssertNil(HomeHelperPairing.normalize("ABCD-EFG"))
        XCTAssertNil(HomeHelperPairing.normalize("ABCD-EFGHJ"))
        XCTAssertNil(HomeHelperPairing.normalize(""))
        XCTAssertEqual(HomeHelperPairing.format("abcdefgh"), "ABCD-EFGH")
    }

    func testRecognizesOnlyThePairingURLAndIgnoresItsOtherParts() throws {
        for text in ["imcp://pair", "IMCP://PAIR", "imcp://pair/extra?code=0123-ABCD#fragment"] {
            XCTAssertTrue(HomeHelperPairing.isPairingURL(try XCTUnwrap(URL(string: text))), text)
        }
        for text in ["imcp://settings", "https://pair", "imcp:pair", "imcp://", "pair://imcp"] {
            XCTAssertFalse(HomeHelperPairing.isPairingURL(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testAppInfoPlistDeclaresThePairingURLScheme() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../App/Info.plist")
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        )
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [HomeHelperPairing.appPairingURL.scheme])
    }

    func testAppsKeepTheirKeysUnderDifferentServices() {
        XCTAssertNotEqual(HomeHelperPairing.Keychain.app.service, HomeHelperPairing.Keychain.helper.service)
    }

    func testDerivesThePinnedPairingKeyForEveryFormOfACode() throws {
        func bytes(_ code: String) throws -> Data {
            try HomeHelperPairing.pairingKey(code: code).withUnsafeBytes { Data($0) }
        }
        // PBKDF2-HMAC-SHA256 with the app's salt; both apps must derive these bytes.
        XCTAssertEqual(
            try bytes("0123-ABCD").map { String(format: "%02x", $0) }.joined(),
            "5eb218a203b5414d4db9a1ae64faf3f34b73540fda9069b62176417c3f317d5b"
        )
        XCTAssertEqual(try bytes("o123 abcd"), try bytes("0123ABCD"))
        XCTAssertThrowsError(try HomeHelperPairing.pairingKey(code: "not a pairing code"))
    }

    func testPairsWithTheCodeThenConnectsOnlyWithTheKey() async throws {
        let code = try HomeHelperPairing.generateCode()
        let events = EventRecorder()
        let helperStore = MemoryKeyStore()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            storeKey: { key, _ in try helperStore.save(key) },
            onEvent: { await events.record($0) }
        )
        let pairingPort = try await server.start()
        let pairing = try HomeHelperPairing.pairingParameters(code: code)

        // A pairing connection can't list tools.
        let pairingClient = try await connectClient(port: pairingPort, parameters: pairing)
        do {
            _ = try await pairingClient.send(ListTools.request(.init())).value
            XCTFail("A pairing connection must not list tools.")
        } catch {}
        await pairingClient.disconnect()

        let store = MemoryKeyStore()
        let pending = MemoryKeyStore()
        let key = HomeHelperPairing.generateKey()
        try await HomeService(keyStore: store, pendingKeyStore: pending).connect(
            to: .hostPort(host: .ipv4(.loopback), port: pairingPort),
            parameters: pairing,
            deadline: .now + .seconds(10),
            purpose: .pair(key)
        )
        XCTAssertEqual(try store.read().map(Self.bytes), Self.bytes(key))
        XCTAssertNil(try pending.read())
        // The helper stored the key before it acknowledged the pairing.
        XCTAssertEqual(try helperStore.read().map(Self.bytes), Self.bytes(key))
        let paired = try await events.next()
        guard case .paired(let received, code: code) = paired else { return XCTFail("\(paired)") }
        XCTAssertEqual(Self.bytes(received), Self.bytes(key))

        // The code works once: the helper stops accepting it as soon as iMCP pairs.
        let reused = try await connectionFails(port: pairingPort, parameters: pairing)
        XCTAssertTrue(reused)

        // The window then listens with the key, which the code can't open.
        let port = try await server.restart(credential: .key(received))
        try await HomeService().connect(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: HomeHelperPairing.parameters(key: key),
            deadline: .now + .seconds(10)
        )
        let codeFails = try await handshakeFails(port: port, parameters: pairing)
        XCTAssertTrue(codeFails)
        let otherKeyFails = try await handshakeFails(
            port: port,
            parameters: HomeHelperPairing.parameters(key: HomeHelperPairing.generateKey())
        )
        XCTAssertTrue(otherKeyFails)
        withExtendedLifetime(server) {}
    }

    func testReplacesTheCodeAfterFiveFailedHandshakes() async throws {
        let code = try HomeHelperPairing.generateCode()
        let events = EventRecorder()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            onEvent: { await events.record($0) }
        )
        let port = try await server.start()
        let wrong = try HomeHelperPairing.pairingParameters(code: HomeHelperPairing.generateCode())
        for _ in 1 ... HomeHelperPairing.failedPairingLimit {
            let failed = try await handshakeFails(port: port, parameters: wrong)
            XCTAssertTrue(failed)
        }
        let event = try await events.next()
        guard case .tooManyFailedPairings(code: code) = event else { return XCTFail("\(event)") }
        // The helper stops accepting guesses until the window shows a new code.
        let stopped = try await connectionFails(
            port: port,
            parameters: try HomeHelperPairing.pairingParameters(code: code)
        )
        XCTAssertTrue(stopped)
        withExtendedLifetime(server) {}
    }

    func testPairAgainEndsTheKeyAndItsSessions() async throws {
        let key = HomeHelperPairing.generateKey()
        let server = HelperServer(backend: StaticHomeBackend(), credential: .key(key))
        let oldPort = try await server.start()
        let session = NWConnection(
            host: .ipv4(.loopback),
            port: oldPort,
            using: HomeHelperPairing.parameters(key: key)
        )
        defer { session.cancel() }
        session.start(queue: .main)
        try await waitUntilReady(session)

        let start = ContinuousClock.now
        let code = try HomeHelperPairing.generateCode()
        let port = try await server.restart(credential: .code(code))
        let ended = await withCheckedContinuation { continuation in
            session.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                continuation.resume(returning: isComplete || error != nil)
            }
        }
        // The server ends sessions that don't initialize after five seconds; Pair Again must be sooner.
        XCTAssertTrue(ended)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))

        let keyFails = try await handshakeFails(port: port, parameters: HomeHelperPairing.parameters(key: key))
        XCTAssertTrue(keyFails)
        let client = try await connectClient(
            port: port,
            parameters: try HomeHelperPairing.pairingParameters(code: code)
        )
        await client.disconnect()
        // Without TLS, the helper sends at most a TLS alert, then closes the connection.
        let plaintext = try await plaintextReply(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, port: port)
        XCTAssertFalse(plaintext?.contains("jsonrpc") ?? false, plaintext ?? "")
        withExtendedLifetime(server) {}
    }

    func testNegotiatesOnlyTheECDHEPSKCipherSuite() async throws {
        let key = HomeHelperPairing.generateKey()
        let server = HelperServer(backend: StaticHomeBackend(), credential: .key(key))
        let port = try await server.start()
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: HomeHelperPairing.parameters(key: key))
        defer { connection.cancel() }
        connection.start(queue: .main)
        try await waitUntilReady(connection)
        let metadata = try XCTUnwrap(
            connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        )
        XCTAssertEqual(
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue,
            0xCCAC  // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
        )
        XCTAssertTrue(HomeHelperPairing.usesCipherSuite(connection))

        // Network.framework accepts its default PSK suites too, so the helper checks the suite itself.
        let plain = NWConnection(host: .ipv4(.loopback), port: port, using: Self.plainPSKParameters(key: key))
        defer { plain.cancel() }
        plain.start(queue: .main)
        try await waitUntilReady(plain)
        XCTAssertFalse(HomeHelperPairing.usesCipherSuite(plain))
        let reply = try await exchange(Self.initialize, on: plain)
        XCTAssertNil(reply)
        withExtendedLifetime(server) {}
    }

    func testRestartCancelsAConnectionThatIsBeingSetUp() async throws {
        let key = HomeHelperPairing.generateKey()
        let gate = Gate()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .key(key),
            willStartSession: { await gate.pass() }
        )
        let port = try await server.start()
        let old = NWConnection(host: .ipv4(.loopback), port: port, using: HomeHelperPairing.parameters(key: key))
        defer { old.cancel() }
        old.start(queue: .main)
        // Restart while the server holds the old connection between its setup and its start.
        try await gate.waitForArrival()
        let newKey = HomeHelperPairing.generateKey()
        let newPort = try await server.restart(credential: .key(newKey))
        await gate.open()
        let reply = try await exchange(Self.initialize, on: old)
        XCTAssertNil(reply, "A connection with the old key answered after the restart.")

        // A connection with the new key gets an answer, so the exchange itself works.
        let current = NWConnection(
            host: .ipv4(.loopback),
            port: newPort,
            using: HomeHelperPairing.parameters(key: newKey)
        )
        defer { current.cancel() }
        current.start(queue: .main)
        try await waitUntilReady(current)
        let answer = try await exchange(Self.initialize, on: current)
        XCTAssertTrue(answer?.contains("iMCP Helper") == true, answer ?? "no reply")
        withExtendedLifetime(server) {}
    }

    func testRejectsAPairingRequestFromAnEndedSession() async throws {
        let code = try HomeHelperPairing.generateCode()
        let events = EventRecorder()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            onEvent: { await events.record($0) }
        )
        let port = try await server.start()
        // swift-sdk can run the handler after its session ended; such a session isn't registered.
        do {
            try await server.receivePairing(Data(count: 32), session: UUID(), code: code)
            XCTFail("A pairing request from an ended session must fail.")
        } catch {}
        let stillAccepted = try await connectionFails(
            port: port,
            parameters: HomeHelperPairing.pairingParameters(code: code)
        )
        XCTAssertFalse(stillAccepted)
        let reported = await events.count
        XCTAssertEqual(reported, 0)
        withExtendedLifetime(server) {}
    }

    func testReportsAPairingWhoseConnectionEndsWhileTheKeyIsStored() async throws {
        let code = try HomeHelperPairing.generateCode()
        let events = EventRecorder()
        let gate = Gate()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            storeKey: { _, _ in await gate.pass() },
            onEvent: { await events.record($0) }
        )
        let port = try await server.start()
        let client = try await connectClient(port: port, parameters: HomeHelperPairing.pairingParameters(code: code))
        let key = HomeHelperPairing.generateKey()
        let request = Task {
            try await client.send(HomeHelperPairing.Pair.request(.init(key: Self.bytes(key)))).value
        }
        // End the connection while the helper stores the key, then let it finish storing.
        try await gate.waitForArrival()
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        await gate.open()
        let event = try await events.next()
        guard case .paired(let reported, code: code) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(Self.bytes(reported), Self.bytes(key))
        request.cancel()
        withExtendedLifetime(server) {}
    }

    private static let initialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"iMCP","version":"1"},"capabilities":{}}}"#

    /// TLS parameters with the paired identity and Network.framework's plain PSK suite.
    private static func plainPSKParameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            options,
            key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            Data("iMCP Helper paired v3".utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.requiredInterfaceType = .loopback
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return parameters
    }

    /// Sends one JSON-RPC message on a started connection and returns the first line of the reply,
    /// or nil if the server closes the connection first or doesn't answer within three seconds.
    private func exchange(_ message: String, on connection: NWConnection) async throws -> String? {
        connection.send(content: Data((message + "\n").utf8), completion: .idempotent)
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
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
            if closed { return nil }
        }
    }

    func testKeepsThePendingKeyWhenTheAcknowledgmentIsLost() async throws {
        let code = try HomeHelperPairing.generateCode()
        // The helper stores the key, but its acknowledgment comes too late for iMCP.
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            storeKey: { _, _ in try await Task.sleep(for: .seconds(6)) }
        )
        let port = try await server.start()
        let store = MemoryKeyStore()
        let pending = MemoryKeyStore()
        let key = HomeHelperPairing.generateKey()
        do {
            try await HomeService(keyStore: store, pendingKeyStore: pending).connect(
                to: .hostPort(host: .ipv4(.loopback), port: port),
                parameters: HomeHelperPairing.pairingParameters(code: code),
                deadline: .now + .seconds(10),
                purpose: .pair(key)
            )
            XCTFail("The pairing must report the lost acknowledgment.")
        } catch {}
        XCTAssertNil(try store.read())
        XCTAssertEqual(try pending.read().map(Self.bytes), Self.bytes(key))
        withExtendedLifetime(server) {}
    }

    func testDropsThePendingKeyWhenTheHelperRefusesThePairing() async throws {
        let code = try HomeHelperPairing.generateCode()
        let server = HelperServer(
            backend: StaticHomeBackend(),
            credential: .code(code),
            storeKey: { _, _ in throw HomeError("The keychain is locked.") }
        )
        let port = try await server.start()
        let store = MemoryKeyStore()
        let pending = MemoryKeyStore()
        do {
            try await HomeService(keyStore: store, pendingKeyStore: pending).connect(
                to: .hostPort(host: .ipv4(.loopback), port: port),
                parameters: HomeHelperPairing.pairingParameters(code: code),
                deadline: .now + .seconds(10),
                purpose: .pair(HomeHelperPairing.generateKey())
            )
            XCTFail("The pairing must fail when the helper can't store the key.")
        } catch {}
        XCTAssertNil(try store.read())
        XCTAssertNil(try pending.read())
        withExtendedLifetime(server) {}
    }

    func testPromotesAPendingKeyThatAConnectionUses() async throws {
        let old = HomeHelperPairing.generateKey()
        let new = HomeHelperPairing.generateKey()
        let store = MemoryKeyStore(old)
        let pending = MemoryKeyStore(new)
        var offered: [[Data]] = []
        try await HomeService(keyStore: store, pendingKeyStore: pending).connectWithSavedKeys { keys in
            offered.append(keys.map(Self.bytes))
            return (index: 1, chosen: true)
        }
        XCTAssertEqual(offered, [[Self.bytes(old), Self.bytes(new)]])
        XCTAssertEqual(try store.read().map(Self.bytes), Self.bytes(new))
        XCTAssertNil(try pending.read())

        // With no saved key, iMCP offers the pending key alone.
        let onlyPending = MemoryKeyStore(new)
        let empty = MemoryKeyStore()
        try await HomeService(keyStore: empty, pendingKeyStore: onlyPending).connectWithSavedKeys { keys in
            XCTAssertEqual(keys.map(Self.bytes), [Self.bytes(new)])
            return (index: 0, chosen: false)
        }
        XCTAssertEqual(try empty.read().map(Self.bytes), Self.bytes(new))
        XCTAssertNil(try onlyPending.read())
    }

    func testDropsAPendingKeyOnlyWhenTheChosenHelperAcceptsTheSavedKey() async throws {
        let key = HomeHelperPairing.generateKey()
        let new = HomeHelperPairing.generateKey()
        let store = MemoryKeyStore(key)
        let pending = MemoryKeyStore(new)
        // Another helper accepted the saved key, so the chosen one may still have the pending key.
        try await HomeService(keyStore: store, pendingKeyStore: pending).connectWithSavedKeys { _ in
            (index: 0, chosen: false)
        }
        XCTAssertEqual(try pending.read().map(Self.bytes), Self.bytes(new))
        // The chosen helper accepted the saved key, so it never stored the pending one.
        try await HomeService(keyStore: store, pendingKeyStore: pending).connectWithSavedKeys { _ in
            (index: 0, chosen: true)
        }
        XCTAssertEqual(try store.read().map(Self.bytes), Self.bytes(key))
        XCTAssertNil(try pending.read())

        // Without either key, iMCP needs pairing.
        do {
            try await HomeService(keyStore: MemoryKeyStore(), pendingKeyStore: MemoryKeyStore())
                .connectWithSavedKeys { _ in (index: 0, chosen: true) }
            XCTFail("Connecting without a key must ask for pairing.")
        } catch HomeService.PairingError.missing {}
    }

    @MainActor
    func testTriesBothKeysWithTheChosenHelperBeforeAnotherHelper() async throws {
        // An older helper still accepts the saved key; the chosen helper stored the pending key.
        let old = HomeHelperPairing.generateKey()
        let new = HomeHelperPairing.generateKey()
        let olderServer = HelperServer(backend: StaticHomeBackend(), credential: .key(old))
        let chosenServer = HelperServer(backend: StaticHomeBackend(), credential: .key(new))
        let olderPort = try await olderServer.start()
        let chosenPort = try await chosenServer.start()
        let suffix = UUID().uuidString.prefix(8)
        var registrations: [DNSServiceRef] = []
        defer { registrations.forEach(DNSServiceRefDeallocate) }
        for (name, port, pid) in [
            ("iMCP Helper Test Older \(suffix)", olderPort, 41001),
            ("iMCP Helper Test Chosen \(suffix)", chosenPort, 41002),
        ] {
            let record = ["protocol=\(HomeHelperPairing.protocolVersion)", "pid=\(pid)"]
                .flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
            var reference: DNSServiceRef?
            let status = DNSServiceRegister(
                &reference,
                0,
                kDNSServiceInterfaceIndexLocalOnly,
                name,
                HomeHelperPairing.serviceType,
                "local.",
                "localhost.",
                port.rawValue.bigEndian,
                UInt16(record.count),
                record,
                nil,
                nil
            )
            XCTAssertEqual(status, DNSServiceErrorType(kDNSServiceErr_NoError))
            let registration = try XCTUnwrap(reference)
            registrations.append(registration)
            DNSServiceSetDispatchQueue(registration, .main)
        }
        let store = MemoryKeyStore(old)
        let pending = MemoryKeyStore(new)
        let service = HomeService(keyStore: store, pendingKeyStore: pending, isRunning: { _ in true })
        try await service.connect(toHelperWithPID: 41002)
        XCTAssertEqual(try store.read().map(Self.bytes), Self.bytes(new))
        XCTAssertNil(try pending.read())
        withExtendedLifetime((olderServer, chosenServer)) {}
    }

    private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @MainActor
    func testResolvesAndDiscoversLocalOnlyServices() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let current = HelperCandidate(
            name: "iMCP Helper Test \(suffix)",
            port: 54321,
            protocolVersion: 3,
            processID: 4242,
            isPairing: true
        )
        let old = HelperCandidate(name: "iMCP Helper Old \(suffix)", port: 54322, protocolVersion: nil, processID: nil)
        var registrations: [DNSServiceRef] = []
        defer { registrations.forEach(DNSServiceRefDeallocate) }
        for (entries, candidate) in [(["protocol=3", "pid=4242", "pairing=1"], current), ([], old)] {
            let name = candidate.name
            let record = entries.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
            var reference: DNSServiceRef?
            let status = DNSServiceRegister(
                &reference,
                0,
                kDNSServiceInterfaceIndexLocalOnly,
                name,
                HomeHelperPairing.serviceType,
                "local.",
                "localhost.",
                candidate.port.rawValue.bigEndian,
                UInt16(record.count),
                record,
                nil,
                nil
            )
            XCTAssertEqual(status, DNSServiceErrorType(kDNSServiceErr_NoError))
            let registration = try XCTUnwrap(reference)
            registrations.append(registration)
            DNSServiceSetDispatchQueue(registration, .main)
            let resolved = try await HelperResolution.resolve(
                name: name,
                type: HomeHelperPairing.serviceType,
                domain: "local."
            )
            XCTAssertEqual(resolved, candidate)
        }
        // Discovery finds every local helper, not only the first one.
        let discovered = await HelperResolution.discover(until: .now + .seconds(3))
        XCTAssertTrue(discovered.contains(current), "\(discovered)")
        XCTAssertTrue(discovered.contains(old), "\(discovered)")
    }

    func testDiscoveryResolutionAndConnectionStopAtTheDeadline() async throws {
        let clock = ContinuousClock()
        var start = clock.now
        _ = await HelperResolution.discover(until: .now + .milliseconds(500))
        XCTAssertLessThan(clock.now - start, .seconds(2))

        start = clock.now
        _ = try? await HelperResolution.resolve(
            name: "No Such Helper \(UUID().uuidString.prefix(8))",
            type: HomeHelperPairing.serviceType,
            domain: "local.",
            until: .now + .milliseconds(300)
        )
        XCTAssertLessThan(clock.now - start, .seconds(2))

        // A peer that accepts TCP connections but never answers the TLS handshake.
        let tcp = NWParameters.tcp
        tcp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: tcp)
        let stalled = OSAllocatedUnfairLock(initialState: [NWConnection]())
        listener.newConnectionHandler = { connection in
            stalled.withLock { $0.append(connection) }
            connection.start(queue: .main)
        }
        listener.start(queue: .main)
        defer {
            listener.cancel()
            stalled.withLock { $0.forEach { $0.cancel() } }
        }
        while listener.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        start = clock.now
        do {
            try await HomeService().connect(
                to: .hostPort(host: .ipv4(.loopback), port: try XCTUnwrap(listener.port)),
                parameters: HomeHelperPairing.parameters(key: HomeHelperPairing.generateKey()),
                deadline: .now + .seconds(1)
            )
            XCTFail("A stalled handshake must not connect.")
        } catch {}
        // The connection waits for the handshake until the deadline, and no longer.
        XCTAssertGreaterThan(clock.now - start, .milliseconds(900))
        XCTAssertLessThan(clock.now - start, .seconds(3))
    }

    func testFirstReadFromAPairedHelperCanOutlastTheSharedDeadline() async throws {
        let key = HomeHelperPairing.generateKey()
        let server = HelperServer(backend: SlowHomeBackend(), credential: .key(key))
        let port = try await server.start()
        // The read takes two seconds, as it can while the helper waits for HomeKit access.
        try await HomeService().connect(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: HomeHelperPairing.parameters(key: key),
            deadline: .now + .seconds(1)
        )
        withExtendedLifetime(server) {}
    }

    func testKeepsEachHelpersLatestResultAcrossPasses() {
        let rejected = HomeService.PairingError.rejected.localizedDescription
        // The chosen helper runs without advertising while another helper rejects the code,
        // and the last pass, at the deadline, finds nothing.
        var log = HomeService.HelperAttemptLog()
        log.record(chosen: [], others: ["iMCP Helper (2)": .rejected])
        XCTAssertNil(log.failure(deadlinePassed: false))
        log.record(chosen: [], others: [:])
        XCTAssertEqual(log.failure(deadlinePassed: true)?.localizedDescription, rejected)

        // A helper's newer result replaces its older one.
        log.record(chosen: [], others: ["iMCP Helper (2)": .unavailable])
        XCTAssertTrue(log.failure(deadlinePassed: true)?.localizedDescription.contains("15 seconds") == true)

        // The chosen helper's results stay while it stops advertising, and decide at the deadline.
        var chosen = HomeService.HelperAttemptLog()
        chosen.record(chosen: [.unavailable], others: [:])
        chosen.record(chosen: [], others: ["iMCP Helper (2)": .rejected])
        XCTAssertTrue(chosen.failure(deadlinePassed: true)?.localizedDescription.contains("15 seconds") == true)
    }

    func testReportsFailuresOnlyAfterEveryCandidateAnswers() {
        typealias Attempts = [(chosen: Bool, attempt: HomeService.HelperAttempt)]
        func failure(_ attempts: Attempts, deadlinePassed: Bool = false) -> String? {
            HomeService.connectionFailure(attempts, deadlinePassed: deadlinePassed)?.localizedDescription
        }
        let rejected = HomeService.PairingError.rejected.localizedDescription
        // Until the chosen helper answers, other helpers' failures don't decide.
        XCTAssertNil(failure([]))
        XCTAssertNil(failure([(false, .outdated), (false, .rejected)]))
        XCTAssertNil(failure([(true, .unavailable), (false, .rejected)]))
        // The chosen helper's answers decide.
        XCTAssertEqual(failure([(true, .rejected), (false, .outdated)]), rejected)
        XCTAssertEqual(failure([(true, .outdated), (true, .rejected)]), rejected)
        XCTAssertTrue(failure([(true, .outdated)])?.contains("Scripts/install-helper.sh") == true)
        // After the deadline, other helpers' answers decide if the chosen one never advertised,
        // an outdated helper first, because it may be the chosen one without a process ID.
        XCTAssertTrue(
            failure([(false, .outdated), (false, .rejected)], deadlinePassed: true)?.contains("install-helper") == true
        )
        XCTAssertEqual(failure([(false, .rejected)], deadlinePassed: true), rejected)
        XCTAssertTrue(failure([(false, .outdated)], deadlinePassed: true)?.contains("install-helper") == true)
        XCTAssertTrue(failure([], deadlinePassed: true)?.contains("didn't appear") == true)
        XCTAssertTrue(failure([(true, .unavailable)], deadlinePassed: true)?.contains("15 seconds") == true)
        // At the deadline, a chosen helper that never answered outweighs another helper's rejection.
        XCTAssertTrue(
            failure([(true, .unavailable), (false, .rejected)], deadlinePassed: true)?.contains("15 seconds") == true
        )
        XCTAssertEqual(failure([(true, .unavailable), (true, .rejected)], deadlinePassed: true), rejected)
    }

    private func connectClient(port: NWEndpoint.Port, parameters: NWParameters) async throws -> MCP.Client {
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
        let client = MCP.Client(name: "iMCP", version: "1")
        let result = try await client.connect(
            transport: NetworkTransport(
                connection: connection,
                heartbeatConfig: .init(enabled: false),
                reconnectionConfig: .disabled
            )
        )
        XCTAssertEqual(result.serverInfo.name, "iMCP Helper")
        return client
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        for _ in 0 ..< 50 {
            if connection.state == .ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HomeError("The connection didn't become ready: \(connection.state)")
    }

    /// Whether a connection fails its TLS handshake with the server.
    private func handshakeFails(port: NWEndpoint.Port, parameters: NWParameters) async throws -> Bool {
        let state = try await finalState(port: port, parameters: parameters)
        switch state {
        case .ready: return false
        case .waiting(.tls), .failed(.tls): return true
        default: throw HomeError("The handshake neither completed nor failed: \(state)")
        }
    }

    /// Whether a connection fails in any way, such as a refused connection or a failed handshake.
    private func connectionFails(port: NWEndpoint.Port, parameters: NWParameters) async throws -> Bool {
        let state = try await finalState(port: port, parameters: parameters)
        if case .ready = state { return false }
        return true
    }

    private func finalState(port: NWEndpoint.Port, parameters: NWParameters) async throws -> NWConnection.State {
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
        defer { connection.cancel() }
        connection.start(queue: .main)
        for _ in 0 ..< 50 {
            try await Task.sleep(for: .milliseconds(100))
            switch connection.state {
            case .ready, .waiting, .failed: return connection.state
            default: continue
            }
        }
        throw HomeError("The connection neither completed nor failed: \(connection.state)")
    }

    /// Sends one JSON-RPC message without TLS and returns the first line of the reply,
    /// or what arrived before the helper closed the connection, or nil if nothing did.
    private func plaintextReply(_ message: String, port: NWEndpoint.Port) async throws -> String? {
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
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

/// Keeps a pairing key in memory instead of the keychain.
private final class MemoryKeyStore: HomeHelperKeyStore {
    private let key = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)
    init(_ key: SymmetricKey? = nil) { self.key.withLock { $0 = key } }
    func read() throws -> SymmetricKey? { key.withLock { $0 } }
    func save(_ key: SymmetricKey) throws { self.key.withLock { $0 = key } }
    func delete() throws { key.withLock { $0 = nil } }
}

/// Holds sessions at the server's `willStartSession` point until the test opens it.
private actor Gate {
    private var arrived = false
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrived = true
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    /// Waits up to five seconds for a session to reach the gate.
    func waitForArrival() async throws {
        for _ in 0 ..< 100 {
            if arrived { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HomeError("No session reached the gate.")
    }
}

/// Collects the server's events in order.
private actor EventRecorder {
    private var events: [HelperServer.Event] = []

    func record(_ event: HelperServer.Event) { events.append(event) }

    var count: Int { events.count }

    /// Returns the oldest event that hasn't been returned, waiting up to five seconds for one.
    func next() async throws -> HelperServer.Event {
        for _ in 0 ..< 100 {
            if !events.isEmpty { return events.removeFirst() }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HomeError("The server reported no event.")
    }
}

private struct SlowHomeBackend: HomeBackend {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        try await Task.sleep(for: .seconds(2))
        return .object(["homes": .array([])])
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

    func testReadsTheProtocolVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func app(_ name: String, _ info: [String: Any]) throws -> URL {
            let url = directory.appendingPathComponent("\(name).app")
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let current = try app(
            "Current",
            [HomeHelperLocator.markerKey: true, HomeHelperPairing.protocolVersionInfoKey: 2]
        )
        XCTAssertEqual(try HomeHelperLocator.protocolVersion(at: current), 2)
        XCTAssertNil(try HomeHelperLocator.protocolVersion(at: try app("Old", [HomeHelperLocator.markerKey: true])))
        // A missing or unreadable Info.plist is an error, not an outdated helper.
        XCTAssertThrowsError(try HomeHelperLocator.protocolVersion(at: directory.appendingPathComponent("Missing.app")))
        let broken = directory.appendingPathComponent("Broken.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: broken.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try HomeHelperLocator.protocolVersion(at: broken.deletingLastPathComponent())) { error in
            XCTAssertTrue(error.localizedDescription.contains("can't read"))
        }
    }

    func testHelperInfoPlistDeclaresTheCurrentProtocolVersion() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Helper/Info.plist")
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        )
        XCTAssertEqual(info[HomeHelperPairing.protocolVersionInfoKey] as? Int, HomeHelperPairing.protocolVersion)
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
