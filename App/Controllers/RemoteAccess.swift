import Foundation
import MCP
import Network
import OSLog

private let log = Logger.server

// MARK: - Tailscale

/// What iMCP reads from the Tailscale command-line tool.
enum Tailscale {
    /// This Mac on its tailnet.
    struct Status: Equatable, Sendable {
        var address: IPv4Address
        /// The MagicDNS name, without the trailing dot.
        var dnsName: String?
        var userID: Int64

        /// The address in dotted decimal form.
        var addressString: String {
            address.rawValue.map(String.init).joined(separator: ".")
        }

        var hostNames: [String] {
            var names = [addressString]
            if let dnsName {
                names.append(dnsName)
                if let label = dnsName.split(separator: ".").first {
                    names.append(String(label))
                }
            }
            return names
        }
    }

    /// The device and user at a tailnet address.
    struct Peer: Equatable, Sendable {
        var deviceName: String
        var userID: Int64
        var isTagged: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case notInstalled
        case notConnected
        case commandFailed(String)
        case unexpectedOutput

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Tailscale isn't installed."
            case .notConnected: "Tailscale isn't connected."
            case .commandFailed(let message): "Tailscale reported an error: \(message)"
            case .unexpectedOutput: "Tailscale returned information that iMCP can't read."
            }
        }
    }

    /// The Tailscale app for macOS includes its command-line tool;
    /// the open source client installs it separately.
    static let executablePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func status() async throws -> Status {
        struct Output: Decodable {
            struct Node: Decodable {
                var TailscaleIPs: [String]?
                var DNSName: String?
                var UserID: Int64
            }
            var BackendState: String
            var selfNode: Node?

            enum CodingKeys: String, CodingKey {
                case BackendState
                case selfNode = "Self"
            }
        }
        let data = try await run(["status", "--json", "--peers=false"])
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw Failure.unexpectedOutput
        }
        guard output.BackendState == "Running", let node = output.selfNode,
            let address = node.TailscaleIPs?.lazy.compactMap(IPv4Address.init).first
        else {
            throw Failure.notConnected
        }
        let dnsName = node.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return Status(address: address, dnsName: dnsName?.isEmpty == false ? dnsName : nil, userID: node.UserID)
    }

    static func whois(_ address: String) async throws -> Peer {
        struct Output: Decodable {
            struct Node: Decodable {
                struct Hostinfo: Decodable {
                    var Hostname: String?
                }
                var ComputedName: String?
                var Name: String?
                var Tags: [String]?
                var User: Int64
                var Hostinfo: Hostinfo?
            }
            var Node: Node
        }
        let data = try await run(["whois", "--json", address])
        guard let node = try? JSONDecoder().decode(Output.self, from: data).Node else {
            throw Failure.unexpectedOutput
        }
        let name = node.Hostinfo?.Hostname ?? node.ComputedName ?? node.Name ?? address
        return Peer(deviceName: name, userID: node.User, isTagged: !(node.Tags ?? []).isEmpty)
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let path = executablePaths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure.notInstalled
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.commandFailed(error.localizedDescription))
                    return
                }
                // Don't wait for a command that hangs.
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                timeout.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: Failure.commandFailed(
                            message.isEmpty ? "exit status \(process.terminationStatus)" : message
                        )
                    )
                }
            }
        }
    }

    /// Whether an IPv4 address is in the tailnet range, 100.64.0.0/10.
    static func isTailnetAddress(_ bytes: [UInt8]) -> Bool {
        bytes.count == 4 && bytes[0] == 100 && bytes[1] & 0xC0 == 64
    }
}

// MARK: - Remote access server

/// Serves MCP over HTTP to the owner's other devices on their tailnet.
///
/// The server listens only on this Mac's tailnet address.
/// Each connection must come from an untagged device that belongs to the same Tailscale user as this Mac,
/// and each request must carry an access token.
/// Sessions follow the 2025-11-25 Streamable HTTP transport.
actor RemoteAccessServer {
    enum State: Equatable, Sendable {
        case off
        case starting
        /// Tailscale isn't available, for the given reason.
        case unavailable(String)
        case running(endpoint: String)
        case failed(String)
    }

    struct Configuration: Equatable, Sendable {
        var isEnabled: Bool
        var port: UInt16
    }

    static let defaultPort: UInt16 = 4627
    static let maximumConnections = 32
    static let maximumSessions = 16
    /// How long a session with no requests and no open streams lasts.
    static let sessionIdleTimeout: TimeInterval = 60 * 60
    /// How often iMCP checks Tailscale for a new address.
    static let refreshInterval: Duration = .seconds(15)

    private struct Session {
        let tokenID: UUID
        let transport: StatefulHTTPServerTransport
        let server: MCP.Server
        var lastActivity: Date
        var openStreams: Int
    }

    private let tokenStore: AccessTokenStore
    private weak var networkManager: ServerNetworkManager?
    private let queue = DispatchQueue(label: "iMCP.RemoteAccess")

    private var configuration = Configuration(isEnabled: false, port: defaultPort)
    private var stateHandler: (@Sendable (State) -> Void)?
    private var tokenUsageHandler: (@Sendable () -> Void)?
    private var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.info("Remote access state: \(String(describing: self.state), privacy: .public)")
            stateHandler?(state)
        }
    }

    private var monitorTask: Task<Void, Never>?
    private var listener: SocketListener?
    /// The Tailscale status that the listener uses.
    private var status: Tailscale.Status?
    private var connectionCount = 0
    private var peers: [String: (peer: Tailscale.Peer?, expires: Date)] = [:]
    private var sessions: [String: Session] = [:]

    init(tokenStore: AccessTokenStore, networkManager: ServerNetworkManager) {
        self.tokenStore = tokenStore
        self.networkManager = networkManager
    }

    func setHandlers(
        state: @escaping @Sendable (State) -> Void,
        tokenUsage: @escaping @Sendable () -> Void
    ) {
        stateHandler = state
        tokenUsageHandler = tokenUsage
        state(self.state)
    }

    func configure(_ configuration: Configuration) async {
        guard configuration != self.configuration else { return }
        let portChanged = configuration.port != self.configuration.port
        self.configuration = configuration

        if portChanged || !configuration.isEnabled {
            stopListener()
        }
        guard configuration.isEnabled else {
            monitorTask?.cancel()
            monitorTask = nil
            await closeSessions { _ in true }
            state = .off
            return
        }

        state = .starting
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() async {
        await configure(Configuration(isEnabled: false, port: configuration.port))
    }

    // MARK: Tokens

    /// Ends the sessions that use a token, after the token is deleted or re-rolled.
    func closeSessions(forToken id: UUID) async {
        await closeSessions { $0.tokenID == id }
    }

    /// Tells clients to fetch their tool lists again.
    /// Pass a token to notify only the sessions that use it.
    func notifyToolListChanged(forToken id: UUID? = nil) async {
        for session in sessions.values where id == nil || session.tokenID == id {
            do {
                try await session.server.notify(ToolListChangedNotification.message())
            } catch {
                log.debug("Couldn't notify a remote session of a tool list change: \(error)")
            }
        }
    }

    // MARK: Listener

    private func refresh() async {
        guard configuration.isEnabled else { return }
        await closeIdleSessions()

        let current: Tailscale.Status
        do {
            current = try await Tailscale.status()
        } catch {
            guard configuration.isEnabled else { return }
            stopListener()
            state = .unavailable(error.localizedDescription)
            return
        }
        guard configuration.isEnabled else { return }
        if listener != nil, current == status { return }
        startListener(on: current)
    }

    private func startListener(on current: Tailscale.Status) {
        stopListener()
        guard configuration.port != 0 else {
            state = .failed("Choose a port from 1 to 65535.")
            return
        }
        do {
            // Listen on the tailnet address only, so that other networks can't reach the server.
            // A kernel socket accepts connections from this Mac's own tailnet address too,
            // which Network.framework's listener on the Tailscale interface doesn't.
            listener = try SocketListener(address: current.address, port: configuration.port, queue: queue) {
                [weak self] connection in
                guard let self else {
                    connection.close()
                    return
                }
                Task { await self.accept(connection) }
            }
        } catch {
            log.error("Remote access listener failed: \(error)")
            if (error as? POSIXError)?.code == .EADDRINUSE {
                state = .failed("Another app is using port \(configuration.port). Choose another port.")
            } else {
                state = .failed("iMCP couldn't listen on port \(configuration.port): \(error.localizedDescription)")
            }
            return
        }
        status = current
        peers.removeAll()
        let host = current.dnsName ?? current.addressString
        state = .running(endpoint: "http://\(host):\(configuration.port)/mcp")
        log.notice("Remote access listening on \(current.addressString, privacy: .public):\(self.configuration.port)")
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        status = nil
    }

    // MARK: Connections

    private func accept(_ connection: SocketConnection) {
        guard listener != nil, connectionCount < Self.maximumConnections,
            Tailscale.isTailnetAddress(connection.peerAddress)
        else {
            connection.close()
            return
        }
        connectionCount += 1

        let address = connection.peerAddress.map(String.init).joined(separator: ".")
        let http = HTTPServerConnection(connection)
        Task {
            let peer = await self.authorizedPeer(at: address)
            await http.serve(
                { request in
                    guard let peer else {
                        let error = MCPError.invalidRequest(
                            "Forbidden: Only devices that belong to the owner of this Mac can connect."
                        )
                        return (MCP.HTTPResponse.error(statusCode: 403, error), keepAlive: false)
                    }
                    let response = await self.respond(to: request, from: peer)
                    Self.logRequest(request, response: response, from: peer)
                    return (response, keepAlive: true)
                },
                streamEnded: { sessionID in await self.streamEnded(sessionID: sessionID) }
            )
            self.connectionClosed()
        }
    }

    private func connectionClosed() {
        connectionCount -= 1
    }

    /// The device at an address, if it belongs to this Mac's user and has no tags.
    private func authorizedPeer(at address: String) async -> Tailscale.Peer? {
        if let cached = peers[address], cached.expires > Date() {
            return cached.peer
        }
        var authorized: Tailscale.Peer?
        do {
            let peer = try await Tailscale.whois(address)
            if let status, peer.userID == status.userID, !peer.isTagged {
                authorized = peer
            } else {
                log.notice(
                    "Rejected remote connection from \(address, privacy: .public): another user or a tagged device"
                )
            }
        } catch {
            log.error("Couldn't identify the remote device at \(address, privacy: .public): \(error)")
        }
        peers[address] = (authorized, Date().addingTimeInterval(60))
        return authorized
    }

    // MARK: Requests

    private var originValidator: OriginValidator {
        let port = configuration.port
        let hosts = status?.hostNames ?? []
        return OriginValidator(
            allowedHosts: hosts.map { "\($0):\(port)" },
            allowedOrigins: hosts.map { "http://\($0):\(port)" }
        )
    }

    /// Logs a request without its body or credentials.
    private static func logRequest(
        _ request: HTTPRequestMessage,
        response: MCP.HTTPResponse,
        from peer: Tailscale.Peer
    ) {
        let method = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["method"] as? String
        log.info(
            "Remote request from \(peer.deviceName, privacy: .public): \(request.method, privacy: .public) \(request.path, privacy: .public) \(method ?? "-", privacy: .public), session \(request.header(HTTPHeaderName.sessionID) == nil ? "none" : "set", privacy: .public), token \(request.header(HTTPHeaderName.authorization) == nil ? "none" : "set", privacy: .public), accept \(request.header("Accept") ?? "-", privacy: .public) -> \(response.statusCode)"
        )
    }

    private func respond(to message: HTTPRequestMessage, from peer: Tailscale.Peer) async -> MCP.HTTPResponse {
        guard message.path == "/mcp" else {
            return .error(statusCode: 404, .invalidRequest("Not Found: The MCP endpoint is /mcp."))
        }
        let request = MCP.HTTPRequest(
            method: message.method,
            headers: message.headers,
            body: message.body.isEmpty ? nil : message.body,
            path: message.path
        )
        let context = HTTPValidationContext(
            httpMethod: message.method,
            sessionID: nil,
            isInitializationRequest: false,
            supportedProtocolVersions: MCP.Version.supported
        )
        if let rejection = originValidator.validate(request, context: context) {
            return rejection
        }

        guard let token = Self.bearerToken(in: request).flatMap(tokenStore.token(secret:)) else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: Send an iMCP access token in the Authorization header."),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: #"Bearer realm="iMCP""#]
            )
        }

        if let sessionID = request.header(HTTPHeaderName.sessionID) {
            // A session belongs to the token that started it.
            guard var session = sessions[sessionID], session.tokenID == token.id else {
                return .error(statusCode: 404, .invalidRequest("Not Found: Session not found."))
            }
            session.lastActivity = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if case .stream = response {
                sessions[sessionID]?.openStreams += 1
            }
            if message.method == "DELETE", response.statusCode == 200 {
                await closeSessions { $0.transport === session.transport }
            }
            return response
        }

        guard message.method == "POST", Self.isInitializeRequest(message.body) else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: Mcp-Session-Id header is required."))
        }
        return await startSession(with: request, token: token, peer: peer)
    }

    private func startSession(
        with request: MCP.HTTPRequest,
        token: AccessToken,
        peer: Tailscale.Peer
    ) async -> MCP.HTTPResponse {
        if sessions.count >= Self.maximumSessions {
            // Make room by ending the session that has waited longest without a request or stream.
            if let oldest = sessions.values.filter({ $0.openStreams == 0 })
                .min(by: { $0.lastActivity < $1.lastActivity })
            {
                await closeSessions { $0.transport === oldest.transport }
            } else {
                return .error(statusCode: 503, .internalError("Service Unavailable: Too many sessions."))
            }
        }
        guard let networkManager else {
            return .error(statusCode: 503, .internalError("Service Unavailable"))
        }

        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                originValidator,
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ])
        )
        let server = MCP.Server.iMCP()
        let tokenID = token.id
        let tokenStore = self.tokenStore
        // Read the token for each request, so that permission changes apply to open sessions.
        await networkManager.registerHandlers(for: server, connectionID: UUID()) { tool in
            tokenStore.token(id: tokenID)?.permissions.allows(tool) ?? false
        }
        do {
            try await server.start(transport: transport)
        } catch {
            log.error("Couldn't start a remote session: \(error)")
            return .error(statusCode: 500, .internalError("Internal error: The session couldn't start."))
        }

        let response = await transport.handleRequest(request)
        guard let sessionID = response.headers[HTTPHeaderName.sessionID] else {
            await server.stop()
            return response
        }
        var openStreams = 0
        if case .stream = response { openStreams = 1 }
        sessions[sessionID] = Session(
            tokenID: tokenID,
            transport: transport,
            server: server,
            lastActivity: Date(),
            openStreams: openStreams
        )
        tokenStore.modify(id: tokenID) {
            $0.lastUsedAt = Date()
            $0.lastUsedDevice = peer.deviceName
        }
        tokenUsageHandler?()
        log.notice(
            "Remote session started with token \(token.name, privacy: .public) from \(peer.deviceName, privacy: .public)"
        )
        return response
    }

    private func streamEnded(sessionID: String?) {
        guard let sessionID, let session = sessions[sessionID] else { return }
        sessions[sessionID]?.openStreams = max(0, session.openStreams - 1)
        sessions[sessionID]?.lastActivity = Date()
    }

    private func closeIdleSessions() async {
        let cutoff = Date().addingTimeInterval(-Self.sessionIdleTimeout)
        await closeSessions { $0.openStreams == 0 && $0.lastActivity < cutoff }
    }

    private func closeSessions(where predicate: (Session) -> Bool) async {
        let closing = sessions.filter { predicate($0.value) }
        for (id, session) in closing {
            sessions.removeValue(forKey: id)
            await session.transport.disconnect()
            await session.server.stop()
        }
        if !closing.isEmpty {
            log.info("Closed \(closing.count) remote sessions")
        }
    }

    private static func bearerToken(in request: MCP.HTTPRequest) -> String? {
        guard let field = request.header(HTTPHeaderName.authorization) else { return nil }
        let parts = field.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    private static func isInitializeRequest(_ body: Data) -> Bool {
        let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return message?["method"] as? String == "initialize"
    }
}

// MARK: - HTTP connection

/// One client connection to the remote access server.
/// It reads a request, writes the response, and repeats while the client keeps the connection open.
final class HTTPServerConnection: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestMessage) async -> (MCP.HTTPResponse, keepAlive: Bool)

    /// How long a connection can wait for a request.
    static let idleTimeout: Duration = .seconds(120)
    /// How often an open event stream gets a comment, so that a closed connection is noticed.
    static let keepAliveInterval: Duration = .seconds(25)

    private let connection: SocketConnection
    private var buffer = Data()

    init(_ connection: SocketConnection) {
        self.connection = connection
    }

    func serve(_ handler: Handler, streamEnded: @Sendable (String?) async -> Void) async {
        defer { connection.close() }
        while let result = await readRequest() {
            switch result {
            case .request(let message, _):
                let (response, keepAlive) = await handler(message)
                let shouldKeepAlive = keepAlive && message.keepAlive
                let sent = await write(response, keepAlive: shouldKeepAlive, streamEnded: streamEnded)
                guard sent, shouldKeepAlive else { return }
            case .failure(let status, let reason):
                _ = await write(
                    .error(statusCode: status, .invalidRequest(reason)),
                    keepAlive: false,
                    streamEnded: streamEnded
                )
                return
            case .incomplete:
                return
            }
        }
    }

    /// The next request, or `nil` when the connection closes first.
    private func readRequest() async -> HTTPRequestParser.Result? {
        var sentContinue = false
        while true {
            let result = HTTPRequestParser.parse(buffer)
            switch result {
            case .request(_, let length):
                buffer =
                    buffer.count > length ? buffer.subdata(in: buffer.startIndex + length ..< buffer.endIndex) : Data()
                return result
            case .failure:
                return result
            case .incomplete(let expectsContinue):
                if expectsContinue, !sentContinue {
                    sentContinue = true
                    guard await send(HTTPResponseEncoder.continueResponse) else { return nil }
                }
                guard let data = await receive() else { return nil }
                buffer.append(data)
            }
        }
    }

    private func receive() async -> Data? {
        let connection = self.connection
        let timeout = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            if !Task.isCancelled { connection.close() }
        }
        defer { timeout.cancel() }
        return await connection.receive()
    }

    private func send(_ data: Data) async -> Bool {
        await connection.send(data)
    }

    private func write(
        _ response: MCP.HTTPResponse,
        keepAlive: Bool,
        streamEnded: @Sendable (String?) async -> Void
    ) async -> Bool {
        guard case .stream(let stream, var headers) = response else {
            let body = response.bodyData ?? Data()
            var data = HTTPResponseEncoder.head(
                status: response.statusCode,
                headers: response.headers,
                contentLength: body.count,
                keepAlive: keepAlive
            )
            data.append(body)
            return await send(data)
        }

        let sessionID = headers[HTTPHeaderName.sessionID]
        headers["X-Accel-Buffering"] = "no"
        let head = HTTPResponseEncoder.head(status: 200, headers: headers, contentLength: nil, keepAlive: keepAlive)
        var sent = await send(head)
        if sent {
            sent = await pipe(stream)
        }
        if sent {
            sent = await send(HTTPResponseEncoder.lastChunk)
        }
        await streamEnded(sessionID)
        return sent
    }

    /// Sends a stream's events as chunks, with a comment while the stream is quiet.
    private func pipe(_ stream: AsyncThrowingStream<Data, Swift.Error>) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    for try await event in stream {
                        guard await self.send(HTTPResponseEncoder.chunk(event)) else { return false }
                    }
                } catch {
                    log.debug("Remote event stream ended with an error: \(error)")
                }
                return true
            }
            group.addTask {
                while true {
                    try? await Task.sleep(for: Self.keepAliveInterval)
                    if Task.isCancelled { return nil }
                    guard await self.send(HTTPResponseEncoder.chunk(Data(": keep-alive\n\n".utf8))) else {
                        return false
                    }
                }
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? false
        }
    }
}

// MARK: - Sockets

/// A TCP listener on one IPv4 address.
final class SocketListener: @unchecked Sendable {
    private let source: DispatchSourceRead

    init(
        address: IPv4Address,
        port: UInt16,
        queue: DispatchQueue,
        accept: @escaping @Sendable (SocketConnection) -> Void
    ) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError.current }
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: address.rawValue) }
        let bound = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socket, 16) == 0, fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else {
            let error = POSIXError.current
            Darwin.close(socket)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler {
            while true {
                var peer = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(socket, $0, &length) }
                }
                guard client >= 0 else { return }
                let peerAddress = withUnsafeBytes(of: peer.sin_addr) { [UInt8]($0) }
                accept(SocketConnection(socket: client, peerAddress: peerAddress))
            }
        }
        source.setCancelHandler { Darwin.close(socket) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

/// An accepted TCP connection.
///
/// Reads wait on a dispatch source; writes run one at a time on their own queue,
/// and closing waits for the write in progress, so a write never reaches a reused descriptor.
final class SocketConnection: @unchecked Sendable {
    /// The peer's IPv4 address, in network byte order.
    let peerAddress: [UInt8]

    private let socket: Int32
    private let readQueue = DispatchQueue(label: "iMCP.RemoteAccess.read")
    private let writeQueue = DispatchQueue(label: "iMCP.RemoteAccess.write")
    private let readSource: DispatchSourceRead
    // Read state, on the read queue.
    private var pendingReceive: CheckedContinuation<Data?, Never>?
    private var isReadSourceSuspended = true
    private var isClosed = false
    // Write state, on the write queue.
    private var isWriteClosed = false

    init(socket: Int32, peerAddress: [UInt8]) {
        self.socket = socket
        self.peerAddress = peerAddress
        // Use blocking writes with a timeout, and don't raise SIGPIPE when the peer goes away.
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        readSource = DispatchSource.makeReadSource(fileDescriptor: socket, queue: readQueue)
        readSource.setEventHandler { [unowned self] in self.readAvailable() }
        readSource.setCancelHandler { Darwin.close(socket) }
    }

    /// The next bytes from the peer, or `nil` when the connection closes.
    func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            readQueue.async { [self] in
                guard !isClosed, pendingReceive == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingReceive = continuation
                if isReadSourceSuspended {
                    isReadSourceSuspended = false
                    readSource.resume()
                }
            }
        }
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(socket, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        // Stop reading until someone asks for more.
        isReadSourceSuspended = true
        readSource.suspend()
        let continuation = pendingReceive
        pendingReceive = nil
        continuation?.resume(returning: count > 0 ? Data(buffer[0 ..< count]) : nil)
    }

    /// Writes all the bytes, and returns whether the peer received them.
    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                guard !isWriteClosed else {
                    continuation.resume(returning: false)
                    return
                }
                let sent = data.withUnsafeBytes { bytes -> Bool in
                    guard var pointer = bytes.baseAddress else { return true }
                    var remaining = bytes.count
                    while remaining > 0 {
                        let count = write(socket, pointer, remaining)
                        if count > 0 {
                            pointer += count
                            remaining -= count
                        } else if count < 0, errno == EINTR {
                            continue
                        } else {
                            return false
                        }
                    }
                    return true
                }
                continuation.resume(returning: sent)
            }
        }
    }

    func close() {
        writeQueue.async { [self] in
            guard !isWriteClosed else { return }
            isWriteClosed = true
            shutdown(socket, SHUT_RDWR)
            readQueue.async { [self] in
                isClosed = true
                // A source must be running for its cancel handler, which closes the socket, to run.
                if isReadSourceSuspended {
                    isReadSourceSuspended = false
                    readSource.resume()
                }
                readSource.cancel()
                let continuation = pendingReceive
                pendingReceive = nil
                continuation?.resume(returning: nil)
            }
        }
    }
}

extension POSIXError {
    fileprivate static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
