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
enum CompanionTLS {
    static func parameters(keys: [(identity: Data, key: SymmetricKey)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let name = identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, name as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(
            options,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        // Pre-shared key cipher suites exist only in TLS 1.2.
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
}

/// A TLS connection that carries newline-delimited JSON:
/// first the companion handshake, then MCP messages.
///
/// The handshake and MCP share one read buffer,
/// and lines that arrive before MCP asks for them wait in the message stream,
/// so no bytes are lost when the handshake ends and MCP begins.
/// When the connection closes, the stream ends with an error,
/// which stops the MCP client's and server's receive loops.
actor CompanionChannel: Transport {
    nonisolated let logger = Logging.Logger(label: "co.dododo.iMCP.companion.channel")
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var reader: Task<Void, Never>?
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var onClose: (@Sendable () async -> Void)?
    private static let maximumLine = 64 * 1024 * 1024

    init(connection: NWConnection) {
        self.connection = connection
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts the connection and waits until TLS is ready.
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
                        throw CompanionError("The connection failed: \(error.localizedDescription)")
                    case .waiting(let error):
                        // TLS failures, such as a key mismatch, report as waiting.
                        connection.cancel()
                        throw CompanionError("The connection failed: \(error.localizedDescription)")
                    case .cancelled: throw CompanionError("The connection was cancelled.")
                    default: continue
                    }
                }
                throw CompanionError("The connection closed before it was ready.")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                connection.cancel()
                throw CompanionError("The connection didn't open within \(timeout).")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
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
        guard !closed else { throw CompanionError("The connection is closed.") }
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
            guard buffer.count < Self.maximumLine else { throw CompanionError("A message exceeded the size limit.") }
            guard !closed else { throw CompanionError("The connection closed.") }
            let chunk = try await receiveChunk()
            guard let chunk else {
                await finish()
                throw CompanionError("The connection closed.")
            }
            buffer.append(chunk)
        }
    }

    func write<T: Encodable>(_ value: T) async throws {
        try await writeLine(CompanionCoding.encoder.encode(value))
    }

    func read<T: Decodable>(_ type: T.Type, timeout: Duration = .seconds(15)) async throws -> T {
        let line = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.readLine() }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Closing the connection ends the pending read, so the group can finish.
                await self.finish()
                throw CompanionError("The other device didn't answer within \(timeout).")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        do {
            return try CompanionCoding.decoder.decode(type, from: line)
        } catch {
            throw CompanionError("The other device sent an unexpected message.")
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

    private static var closedError: CompanionError { CompanionError("The connection closed.") }

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
enum CompanionDialer {
    struct Credentials: Sendable {
        var identity: Data
        var key: SymmetricKey
        var hello: CompanionHello
    }

    /// Credentials for the first connection, from the scanned QR code.
    static func pairing(_ code: CompanionPairingCode, device: String, name: String) -> Credentials {
        let key = CompanionLink.pairingKey(secret: code.secret)
        return Credentials(
            identity: CompanionLink.pairingIdentity(code.pairingID),
            key: key,
            hello: CompanionHello(
                version: CompanionLink.protocolVersion,
                device: device,
                name: name,
                pairing: code.pairingID,
                proof: CompanionLink.proof(key: key, device: device, purpose: "pair:\(code.pairingID)")
            )
        )
    }

    /// Credentials for later connections, from the device key the Mac issued.
    static func paired(device: String, name: String, key: SymmetricKey, revoke: Bool = false) -> Credentials {
        let purpose = revoke ? "revoke" : "connect"
        return Credentials(
            identity: CompanionLink.deviceIdentity(device),
            key: key,
            hello: CompanionHello(
                version: CompanionLink.protocolVersion,
                device: device,
                name: name,
                pairing: nil,
                proof: CompanionLink.proof(key: key, device: device, purpose: purpose),
                revoke: revoke ? true : nil
            )
        )
    }

    static func connect(
        to endpoint: NWEndpoint,
        with credentials: Credentials,
        timeout: Duration = .seconds(15)
    ) async throws -> (CompanionChannel, CompanionWelcome) {
        let connection = NWConnection(
            to: endpoint,
            using: CompanionTLS.parameters(keys: [(credentials.identity, credentials.key)])
        )
        let channel = CompanionChannel(connection: connection)
        do {
            try await channel.open(timeout: timeout)
            try await channel.write(credentials.hello)
            let welcome = try await channel.read(CompanionWelcome.self, timeout: timeout)
            guard welcome.ok else {
                throw CompanionError(welcome.error ?? "The Mac refused the connection.")
            }
            return (channel, welcome)
        } catch {
            await channel.disconnect()
            throw error
        }
    }
}

/// Serves the phone's tools as an MCP server on an authenticated channel.
enum CompanionPeer {
    static func serve(_ channel: CompanionChannel, tools: [Tool], version: String) async throws {
        let server = MCP.Server(
            name: CompanionLink.serverName,
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
                    throw CompanionError("Unknown companion tool: \(params.name)")
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
