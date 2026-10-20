import CryptoKit
import Foundation
import Logging
import MCP
import Network
import Ontology

/// TLS settings for the link between the phone and the Mac.
///
/// Both sides authenticate with a pre-shared key:
/// the pairing secret from the QR code the first time,
/// and a key for the device after that.
/// A peer without the key can't complete the handshake.
/// The handshake also runs an ephemeral X25519 key exchange,
/// so someone who later gets the key can't decrypt traffic they recorded.
enum MobileTLS {
    /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`,
    /// which combines the pre-shared key with an ephemeral key exchange.
    ///
    /// The TLS stack also offers the plain pre-shared key suites,
    /// which have no forward secrecy, and a server picks by its own order,
    /// so `MobileChannel` closes a connection that negotiated another suite.
    static let cipherSuite = UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256)

    static func parameters(keys: [(identity: Data, key: SymmetricKey)]) -> NWParameters {
        parameters(keys: keys, cipherSuite: cipherSuite)
    }

    /// Parameters that offer `cipherSuite`; tests use another suite to check the rejection.
    static func parameters(keys: [(identity: Data, key: SymmetricKey)], cipherSuite: UInt16) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let name = identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, name as __DispatchData)
        }
        // The suite isn't in `tls_ciphersuite_t`, so it's created from its IANA value.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: cipherSuite)!)
        // TLS 1.3 has pre-shared keys too,
        // but Apple's TLS stack doesn't support external pre-shared keys in TLS 1.3,
        // so the link uses TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The cipher suite that a ready connection negotiated.
    static func negotiatedCipherSuite(_ connection: NWConnection) -> UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }
}

/// A TLS connection that carries newline-delimited JSON:
/// first the pairing or connection handshake, then MCP messages.
///
/// The handshake and MCP share one read buffer,
/// and lines that arrive before MCP asks for them wait in the message stream,
/// so no bytes are lost when the handshake ends and MCP begins.
/// When the connection closes, the stream ends with an error,
/// which stops the MCP client's and server's receive loops.
actor MobileChannel: Transport {
    nonisolated let logger = Logging.Logger(label: "co.dododo.iMCP.mobile.channel")
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var reader: Task<Void, Never>?
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var onClose: (@Sendable () async -> Void)?
    private static let maximumLine = 64 * 1024 * 1024

    /// The cipher suite that TLS negotiated, after `open()` succeeds.
    private(set) var cipherSuite: UInt16?

    init(connection: NWConnection) {
        self.connection = connection
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts the connection and waits until TLS is ready.
    /// Closes the connection if it didn't negotiate `MobileTLS.cipherSuite`.
    func open(timeout: Duration = .seconds(15)) async throws {
        let connection = self.connection
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let states = AsyncStream<NWConnection.State> { continuation in
                    connection.stateUpdateHandler = { state in
                        continuation.yield(state)
                        switch state {
                        case .ready, .failed, .cancelled: continuation.finish()
                        default: break
                        }
                    }
                }
                connection.start(queue: .global())
                for await state in states {
                    switch state {
                    case .ready: return
                    case .failed(let error):
                        throw MobileError("The connection failed: \(error.localizedDescription)")
                    case .waiting(let error):
                        // TLS failures, such as a key mismatch, report as waiting.
                        connection.cancel()
                        throw MobileError("The connection failed: \(error.localizedDescription)")
                    case .cancelled: throw MobileError("The connection was cancelled.")
                    default: continue
                    }
                }
                throw MobileError("The connection closed before it was ready.")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                connection.cancel()
                throw MobileError("The connection didn't open within \(timeout).")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        let suite = MobileTLS.negotiatedCipherSuite(connection)
        guard suite == MobileTLS.cipherSuite else {
            await finish()
            throw MobileError(
                "The connection didn't negotiate forward secrecy (cipher suite \(suite.map { String(format: "0x%04X", $0) } ?? "unknown")), so iMCP closed it."
            )
        }
        cipherSuite = suite
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.finish() }
            default: break
            }
        }
    }

    /// Calls `handler` once when the connection closes.
    func setCloseHandler(_ handler: @escaping @Sendable () async -> Void) {
        if closed {
            Task { await handler() }
        } else {
            onClose = handler
        }
    }

    var isClosed: Bool { closed }

    // MARK: - Lines

    func writeLine(_ data: Data) async throws {
        guard !closed else { throw MobileError("The connection is closed.") }
        var line = data
        line.append(UInt8(ascii: "\n"))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: line,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func readLine() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            guard buffer.count < Self.maximumLine else { throw MobileError("A message exceeded the size limit.") }
            guard !closed else { throw MobileError("The connection closed.") }
            let chunk = try await receiveChunk()
            guard let chunk else {
                await finish()
                throw MobileError("The connection closed.")
            }
            buffer.append(chunk)
        }
    }

    func write<T: Encodable>(_ value: T) async throws {
        try await writeLine(MobileCoding.encoder.encode(value))
    }

    func read<T: Decodable>(_ type: T.Type, timeout: Duration = .seconds(15)) async throws -> T {
        let line = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.readLine() }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Closing the connection ends the pending read, so the group can finish.
                await self.finish()
                throw MobileError("The other device didn't answer within \(timeout).")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        do {
            return try MobileCoding.decoder.decode(type, from: line)
        } catch {
            throw MobileError("The other device sent an unexpected message.")
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Transport

    func connect() async throws {
        guard reader == nil else { return }
        reader = Task {
            do {
                while !Task.isCancelled {
                    let line = try await self.readLine()
                    if !line.isEmpty { self.yield(line) }
                }
            } catch {
                await self.finish()
            }
        }
    }

    func disconnect() async {
        await finish()
    }

    func send(_ data: Data) async throws {
        try await writeLine(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard closed else { return messages }
        // A closed stream can't be read again; fail at once so callers stop asking.
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        continuation.finish(throwing: Self.closedError)
        return stream
    }

    private static var closedError: MobileError { MobileError("The connection closed.") }

    private func yield(_ line: Data) {
        continuation.yield(line)
    }

    private func finish() async {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        connection.cancel()
        continuation.finish(throwing: Self.closedError)
        let handler = onClose
        onClose = nil
        await handler?()
    }
}

// MARK: - Phone side

/// Connects the phone to the Mac and authenticates it.
enum MobileDialer {
    struct Credentials: Sendable {
        var identity: Data
        var key: SymmetricKey
        var hello: MobileHello
        /// When pairing: the phone's half of the key exchange.
        var exchange: Curve25519.KeyAgreement.PrivateKey?

        /// The device key from a pairing welcome, or nil for a connection that isn't pairing.
        /// Throws if the Mac's proof doesn't cover the exchange.
        func deviceKey(from welcome: MobileWelcome) throws -> SymmetricKey? {
            guard let exchange, let pairingID = hello.pairing else { return nil }
            let phone = exchange.publicKey.rawRepresentation
            guard let mac = welcome.exchange, let proof = welcome.proof,
                MobileLink.verify(
                    proof,
                    key: key,
                    device: hello.device,
                    purpose: "welcome:\(pairingID)",
                    context: phone + mac
                )
            else {
                throw MobileError("The Mac's pairing answer couldn't be verified. Show a new code and try again.")
            }
            return try MobileKeyExchange.deviceKey(
                privateKey: exchange,
                peer: mac,
                pairingKey: key,
                device: hello.device,
                phone: phone,
                mac: mac
            )
        }
    }

    /// An authenticated connection, with the device key when it was a pairing.
    struct Session: Sendable {
        var channel: MobileChannel
        var welcome: MobileWelcome
        var deviceKey: SymmetricKey?
    }

    /// Credentials for the first connection, from the scanned QR code.
    static func pairing(_ code: MobilePairingCode, device: String, name: String) -> Credentials {
        let key = MobileLink.pairingKey(secret: code.secret)
        let exchange = Curve25519.KeyAgreement.PrivateKey()
        let phone = exchange.publicKey.rawRepresentation
        return Credentials(
            identity: MobileLink.pairingIdentity(code.pairingID),
            key: key,
            hello: MobileHello(
                version: MobileLink.protocolVersion,
                device: device,
                name: name,
                pairing: code.pairingID,
                proof: MobileLink.proof(
                    key: key,
                    device: device,
                    purpose: "pair:\(code.pairingID)",
                    context: phone
                ),
                exchange: phone
            ),
            exchange: exchange
        )
    }

    /// Credentials for later connections, from the device key that pairing derived.
    static func paired(device: String, name: String, key: SymmetricKey, revoke: Bool = false) -> Credentials {
        let purpose = revoke ? "revoke" : "connect"
        return Credentials(
            identity: MobileLink.deviceIdentity(device),
            key: key,
            hello: MobileHello(
                version: MobileLink.protocolVersion,
                device: device,
                name: name,
                pairing: nil,
                proof: MobileLink.proof(key: key, device: device, purpose: purpose),
                revoke: revoke ? true : nil
            )
        )
    }

    static func connect(
        to endpoint: NWEndpoint,
        with credentials: Credentials,
        timeout: Duration = .seconds(15)
    ) async throws -> Session {
        let connection = NWConnection(
            to: endpoint,
            using: MobileTLS.parameters(keys: [(credentials.identity, credentials.key)])
        )
        let channel = MobileChannel(connection: connection)
        do {
            try await channel.open(timeout: timeout)
            try await channel.write(credentials.hello)
            let welcome = try await channel.read(MobileWelcome.self, timeout: timeout)
            guard welcome.ok else {
                throw MobileError(welcome.error ?? "The Mac refused the connection.")
            }
            return Session(channel: channel, welcome: welcome, deviceKey: try credentials.deviceKey(from: welcome))
        } catch {
            await channel.disconnect()
            throw error
        }
    }
}

/// Serves the phone's tools as an MCP server on an authenticated channel.
enum MobilePeer {
    static func serve(_ channel: MobileChannel, tools: [Tool], version: String) async throws {
        let server = MCP.Server(
            name: MobileLink.serverName,
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            try ListTools.Result(
                tools: tools.map { tool in
                    MCP.Tool(
                        name: tool.name,
                        description: tool.description,
                        inputSchema: try Value(tool.inputSchema),
                        annotations: tool.annotations
                    )
                }
            )
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                guard let tool = tools.first(where: { $0.name == params.name }) else {
                    throw MobileError("Unknown tool: \(params.name)")
                }
                try ToolInput.validate(params.arguments ?? [:], schema: tool.inputSchema)
                let value = try await tool.callAsFunction(params.arguments ?? [:])
                let encoder = JSONEncoder()
                encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let text = String(decoding: try encoder.encode(value), as: UTF8.self)
                return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return CallTool.Result(
                    content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
        try await server.start(transport: channel)
        await server.waitUntilCompleted()
        await server.stop()
    }
}
