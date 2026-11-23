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

/// A transport channel between the Mac and the phone that supports close notifications.
protocol MobileTransportChannel: Transport, Sendable {
    var isClosed: Bool { get async }
    func setCloseHandler(_ handler: @escaping @Sendable () async -> Void) async
}

/// A TLS connection that carries newline-delimited JSON:
/// first the pairing or connection handshake, then MCP messages.
///
/// The handshake and MCP share one read buffer,
/// and lines that arrive before MCP asks for them wait in the message stream,
/// so no bytes are lost when the handshake ends and MCP begins.
/// When the connection closes, the stream ends with an error,
/// which stops the MCP client's and server's receive loops.
actor MobileChannel: MobileTransportChannel {
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
    static func serve(_ channel: any MobileTransportChannel, tools: [Tool], version: String) async throws {
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

// MARK: - Byte streams & WebSocket framing

/// A bidirectional byte stream used by WebSocket server connections.
protocol MobileByteStream: Sendable {
    func receive(timeout: Duration) async throws -> Data
    func send(_ data: Data, timeout: Duration) async throws
    func close() async
}

/// Adapts an `NWConnection` to `MobileByteStream`.
final class MobileNWByteStream: MobileByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "co.dododo.iMCP.mobile.ws-stream")

    init(connection: NWConnection) {
        self.connection = connection
    }

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
                connection.start(queue: self.queue)
                for await state in states {
                    switch state {
                    case .ready: return
                    case .failed(let error):
                        throw MobileError("The connection failed: \(error.localizedDescription)")
                    case .cancelled:
                        throw MobileError("The connection was cancelled.")
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
    }

    func receive(timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                        data,
                        _,
                        isComplete,
                        error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(returning: Data())
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                self.connection.cancel()
                throw MobileError("Timed out waiting for data.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func send(_ data: Data, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.connection.send(
                        content: data,
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
            group.addTask {
                try await Task.sleep(for: timeout)
                self.connection.cancel()
                throw MobileError("Timed out sending data.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func close() async {
        connection.cancel()
    }
}

/// Message-framed transport used underneath `MobileEncryptedChannel`.
protocol MobileFrameWire: Sendable {
    func sendFrame(_ data: Data) async throws
    /// Returns `nil` when the peer closes cleanly.
    func receiveFrame() async throws -> Data?
    func close() async
}

/// RFC 6455 WebSocket handshake helpers for server-side upgrade handling.
enum MobileWebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func isUpgradeRequest(method: String, headers: [String: String]) -> Bool {
        guard method.uppercased() == "GET" else { return false }
        let upgrade = header("Upgrade", in: headers)?.lowercased() ?? ""
        let connection = header("Connection", in: headers)?.lowercased() ?? ""
        let key = header("Sec-WebSocket-Key", in: headers)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return upgrade.contains("websocket") && connection.contains("upgrade") && !key.isEmpty
    }

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    static func responseData(clientKey: String) -> Data {
        let accept = acceptKey(for: clientKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(response.utf8)
    }

    /// Reads an HTTP/1.1 WebSocket upgrade request from a fresh byte stream (for local tunnel endpoints),
    /// writes the `101 Switching Protocols` response, and returns any leftover buffered bytes.
    static func accept(
        from stream: any MobileByteStream,
        allowedPaths: Set<String> = [MobileLink.mobileWebSocketPath, "/"]
    )
        async throws -> Data
    {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while buffer.range(of: terminator) == nil {
            guard buffer.count <= 16 * 1024 else {
                throw MobileError("WebSocket upgrade header exceeded size limit.")
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                throw MobileError("WebSocket upgrade timed out.")
            }
            let chunk = try await stream.receive(timeout: remaining)
            guard !chunk.isEmpty else {
                throw MobileError("The WebSocket client closed before upgrading.")
            }
            buffer.append(chunk)
        }
        let range = buffer.range(of: terminator)!
        guard let head = String(data: buffer[buffer.startIndex ..< range.lowerBound], encoding: .utf8) else {
            throw MobileError("Invalid WebSocket upgrade header.")
        }
        let leftover = Data(buffer[range.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count >= 2 else {
            throw MobileError("Invalid HTTP request line.")
        }
        let method = String(requestLine[0])
        let rawTarget = String(requestLine[1])
        let path = String(rawTarget.split(separator: "?", maxSplits: 1)[0])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard allowedPaths.contains(path),
            isUpgradeRequest(method: method, headers: headers),
            let clientKey = header("Sec-WebSocket-Key", in: headers)
        else {
            let reply = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try? await stream.send(Data(reply.utf8), timeout: .seconds(5))
            throw MobileError("Rejected non-WebSocket request.")
        }
        try await stream.send(responseData(clientKey: clientKey), timeout: .seconds(5))
        return leftover
    }
}

/// Server-side RFC 6455 WebSocket framer over a `MobileByteStream`.
actor MobileServerWebSocketWire: MobileFrameWire {
    private let stream: any MobileByteStream
    private var buffer: Data
    private var closed = false
    private static let maximumFrameSize = 64 * 1024 * 1024

    init(stream: any MobileByteStream, initialBuffer: Data = Data()) {
        self.stream = stream
        self.buffer = initialBuffer
    }

    func sendFrame(_ data: Data) async throws {
        guard !closed else { throw MobileError("The WebSocket connection is closed.") }
        let frame = encodeFrame(opcode: 0x02, payload: data)
        try await stream.send(frame, timeout: .seconds(30))
    }

    func receiveFrame() async throws -> Data? {
        var fragmented = Data()
        var expectingContinuation = false

        while true {
            guard !closed else { return nil }
            let headerBytes = try await readExact(2)
            let b0 = headerBytes[0]
            let b1 = headerBytes[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            guard masked else {
                await close()
                throw MobileError("Client WebSocket frame was not masked.")
            }

            let len7 = UInt64(b1 & 0x7F)
            let payloadLength: Int
            if len7 < 126 {
                payloadLength = Int(len7)
            } else if len7 == 126 {
                let ext = try await readExact(2)
                payloadLength = Int(UInt16(ext[0]) << 8 | UInt16(ext[1]))
            } else {
                let ext = try await readExact(8)
                var value: UInt64 = 0
                for byte in ext { value = (value << 8) | UInt64(byte) }
                guard value <= UInt64(Self.maximumFrameSize) else {
                    await close()
                    throw MobileError("WebSocket frame exceeded size limit.")
                }
                payloadLength = Int(value)
            }
            guard payloadLength <= Self.maximumFrameSize else {
                await close()
                throw MobileError("WebSocket frame exceeded size limit.")
            }

            let maskKey = try await readExact(4)
            var payload = payloadLength > 0 ? try await readExact(payloadLength) : Data()
            if payloadLength > 0 {
                for index in 0 ..< payloadLength {
                    payload[index] ^= maskKey[index % 4]
                }
            }

            switch opcode {
            case 0x08:  // Close
                let closeFrame = encodeFrame(opcode: 0x08, payload: Data())
                try? await stream.send(closeFrame, timeout: .seconds(5))
                await close()
                return nil
            case 0x09:  // Ping -> Pong
                let pong = encodeFrame(opcode: 0x0A, payload: payload)
                try? await stream.send(pong, timeout: .seconds(5))
                continue
            case 0x0A:  // Pong
                continue
            case 0x01, 0x02:  // Text or Binary
                if fin && !expectingContinuation {
                    return payload
                }
                fragmented = payload
                expectingContinuation = true
            case 0x00:  // Continuation
                guard expectingContinuation else {
                    await close()
                    throw MobileError("Unexpected WebSocket continuation frame.")
                }
                guard fragmented.count + payload.count <= Self.maximumFrameSize else {
                    await close()
                    throw MobileError("WebSocket message exceeded size limit.")
                }
                fragmented.append(payload)
                if fin { return fragmented }
            default:
                await close()
                throw MobileError("Unsupported WebSocket opcode \(opcode).")
            }
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await stream.close()
    }

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            guard !closed else { throw MobileError("The WebSocket connection closed.") }
            let chunk = try await stream.receive(timeout: .seconds(180))
            guard !chunk.isEmpty else {
                await close()
                throw MobileError("The WebSocket connection closed.")
            }
            buffer.append(chunk)
        }
        let slice = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return slice
    }

    private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            var len = UInt16(count).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127)
            var len = UInt64(count).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }
}

/// Client-side WebSocket transport backed by `URLSessionWebSocketTask`.
final class MobileClientWebSocketWire: MobileFrameWire, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var closed = false

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session
        self.task = session.webSocketTask(with: url)
        self.task.maximumMessageSize = 64 * 1024 * 1024
        self.task.resume()
    }

    func sendFrame(_ data: Data) async throws {
        guard !isClosed else { throw MobileError("The WebSocket connection is closed.") }
        try await task.send(.data(data))
    }

    func receiveFrame() async throws -> Data? {
        guard !isClosed else { return nil }
        let message = try await task.receive()
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return nil
        }
    }

    func close() async {
        let shouldClose = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private var isClosed: Bool { lock.withLock { closed } }
}

/// Application-layer AEAD channel (`ChaChaPoly`) over a frame-based wire (such as WebSocket).
///
/// Uses directional keys derived by `MobileKeyExchange.sessionKeys` and strictly increasing
/// 64-bit counters in nonces and associated data to prevent replay, reordering, and reflection.
actor MobileEncryptedChannel: MobileTransportChannel {
    nonisolated let logger = Logging.Logger(label: "co.dododo.iMCP.mobile.encrypted-channel")
    private let wire: any MobileFrameWire
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var closed = false
    private var reader: Task<Void, Never>?
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var onClose: (@Sendable () async -> Void)?

    init(
        wire: any MobileFrameWire,
        sendKey: SymmetricKey,
        receiveKey: SymmetricKey,
        role: MobileKeyExchange.Role
    ) {
        self.wire = wire
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        switch role {
        case .phone:
            self.sendDirection = 0x01
            self.receiveDirection = 0x02
        case .mac:
            self.sendDirection = 0x02
            self.receiveDirection = 0x01
        }
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
    }

    var isClosed: Bool { closed }

    func setCloseHandler(_ handler: @escaping @Sendable () async -> Void) {
        if closed {
            Task { await handler() }
        } else {
            onClose = handler
        }
    }

    func connect() async throws {
        guard reader == nil else { return }
        reader = Task {
            do {
                while !Task.isCancelled {
                    guard let frame = try await wire.receiveFrame() else {
                        await self.finish()
                        return
                    }
                    let plaintext = try self.open(frame)
                    if !plaintext.isEmpty {
                        self.continuation.yield(plaintext)
                    }
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
        guard !closed else { throw MobileError("The encrypted channel is closed.") }
        let sealed = try seal(data)
        try await wire.sendFrame(sealed)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard closed else { return messages }
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        continuation.finish(throwing: Self.closedError)
        return stream
    }

    private func seal(_ plaintext: Data) throws -> Data {
        guard sendCounter < UInt64.max else { throw MobileError("Message counter exhausted.") }
        let counter = sendCounter
        sendCounter += 1
        let nonceData = Self.nonceBytes(counter: counter)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let aad = Data([sendDirection]) + nonceData
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        return box.combined
    }

    private func open(_ combined: Data) throws -> Data {
        guard receiveCounter < UInt64.max else { throw MobileError("Message counter exhausted.") }
        let expectedNonce = Self.nonceBytes(counter: receiveCounter)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        guard Data(box.nonce) == expectedNonce else {
            throw MobileError("Out-of-order or replayed encrypted message.")
        }
        receiveCounter += 1
        let aad = Data([receiveDirection]) + expectedNonce
        return try ChaChaPoly.open(box, using: receiveKey, authenticating: aad)
    }

    private static func nonceBytes(counter: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static var closedError: MobileError { MobileError("The connection closed.") }

    private func finish() async {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        await wire.close()
        continuation.finish(throwing: Self.closedError)
        let handler = onClose
        onClose = nil
        await handler?()
    }
}

/// Connects the phone to the Mac over `wss://` (or `ws://`) WebSocket with app-layer AEAD.
enum MobileWebSocketDialer {
    struct Session: Sendable {
        var channel: MobileEncryptedChannel
        var welcome: MobileWelcome
        var deviceKey: SymmetricKey?
    }

    static func pairing(_ code: MobilePairingCode, device: String, name: String) -> MobileDialer.Credentials {
        MobileDialer.pairing(code, device: device, name: name)
    }

    static func paired(
        device: String,
        name: String,
        key: SymmetricKey,
        revoke: Bool = false
    ) -> MobileDialer.Credentials {
        let exchange = Curve25519.KeyAgreement.PrivateKey()
        let phone = exchange.publicKey.rawRepresentation
        let purpose = revoke ? "revoke" : "connect"
        return MobileDialer.Credentials(
            identity: MobileLink.deviceIdentity(device),
            key: key,
            hello: MobileHello(
                version: MobileLink.protocolVersion,
                device: device,
                name: name,
                pairing: nil,
                proof: MobileLink.proof(key: key, device: device, purpose: purpose, context: phone),
                revoke: revoke ? true : nil,
                exchange: phone
            ),
            exchange: exchange
        )
    }

    static func connect(
        to url: URL,
        with credentials: MobileDialer.Credentials,
        timeout: Duration = .seconds(15)
    ) async throws -> Session {
        let wire = MobileClientWebSocketWire(url: url)
        do {
            let welcome = try await withThrowingTaskGroup(of: MobileWelcome.self) { group in
                group.addTask {
                    let helloData = try MobileCoding.encoder.encode(credentials.hello)
                    try await wire.sendFrame(helloData)
                    guard let frame = try await wire.receiveFrame() else {
                        throw MobileError("The Mac closed the WebSocket connection.")
                    }
                    return try MobileCoding.decoder.decode(MobileWelcome.self, from: frame)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await wire.close()
                    throw MobileError("The Mac didn't answer within \(timeout).")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard welcome.ok else {
                throw MobileError(welcome.error ?? "The Mac refused the connection.")
            }
            guard let exchange = credentials.exchange,
                let macPub = welcome.exchange,
                let proof = welcome.proof
            else {
                throw MobileError("The Mac didn't complete the encrypted key exchange.")
            }
            let phonePub = exchange.publicKey.rawRepresentation
            let deviceKey: SymmetricKey?
            if credentials.hello.pairing != nil {
                deviceKey = try credentials.deviceKey(from: welcome)
            } else {
                let purpose = credentials.hello.revoke == true ? "revoke" : "connect"
                guard
                    MobileLink.verify(
                        proof,
                        key: credentials.key,
                        device: credentials.hello.device,
                        purpose: "welcome:\(purpose)",
                        context: phonePub + macPub
                    )
                else {
                    throw MobileError("The Mac's answer couldn't be verified.")
                }
                deviceKey = nil
            }
            let (sendKey, receiveKey) = try MobileKeyExchange.sessionKeys(
                privateKey: exchange,
                peer: macPub,
                psk: credentials.key,
                device: credentials.hello.device,
                phone: phonePub,
                mac: macPub,
                role: .phone
            )
            let channel = MobileEncryptedChannel(
                wire: wire,
                sendKey: sendKey,
                receiveKey: receiveKey,
                role: .phone
            )
            return Session(channel: channel, welcome: welcome, deviceKey: deviceKey)
        } catch {
            await wire.close()
            throw error
        }
    }
}

// MARK: - Route selection

/// Tries the routes to a Mac one after another.
enum MobileRoutes {
    /// The longest that one route may take while another is still left to try.
    static let candidateBudget: Duration = .seconds(6)

    /// Returns the first route that `attempt` connects, trying them in order within `total`.
    /// A route that isn't the last gets at most `candidateBudget`,
    /// so a dead route can't use up the time that the next one needs,
    /// and the last gets whatever is left.
    static func firstReachable<T>(
        _ candidates: [MobileTransportCandidate],
        within total: Duration,
        budget candidateBudget: Duration = MobileRoutes.candidateBudget,
        attempt: (MobileTransportCandidate, Duration) async throws -> T
    ) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: total)
        var failures: [String] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            let budget = index == candidates.count - 1 ? remaining : min(remaining, candidateBudget)
            do {
                return try await attempt(candidate, budget)
            } catch {
                if error is CancellationError { throw error }
                failures.append("\(candidate.mode.shortLabel): \(error.localizedDescription)")
            }
        }
        throw MobileError(
            failures.isEmpty
                ? "Couldn't reach the Mac in time."
                : "Couldn't reach the Mac. " + failures.joined(separator: " ")
        )
    }
}
