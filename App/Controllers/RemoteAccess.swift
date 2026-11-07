import Foundation
import MCP
import OSLog

private let log = Logger.server

// MARK: - Tailnet node

/// What iMCP needs to start its own node on a tailnet.
struct TailnetNodeConfiguration: Equatable, Sendable {
    /// The name that the node asks for on the tailnet.
    var hostname: String
    /// The directory where the node keeps its keys and state.
    var stateDirectory: URL
    /// A key that logs the node in without a browser.
    /// iMCP uses it for one start and doesn't keep it.
    var authKey: String?
}

/// iMCP's own node on a tailnet.
///
/// The app uses an embedded Tailscale node;
/// tests use a fake, so that they don't need a tailnet.
protocol TailnetNode: Sendable {
    func status() async throws -> TailnetStatus
    /// The device and user at a tailnet IP address.
    func whois(_ address: String) async throws -> TailnetPeer
    /// Listens for TCP connections on one of the node's tailnet addresses.
    func listen(on address: String, port: UInt16) async throws -> any TailnetListener
    func logout() async throws
    /// Stops the node.
    /// The node's listeners and connections close.
    func close() async
}

protocol TailnetListener: Sendable {
    /// The next connection.
    /// Throws when the listener closes.
    func accept() async throws -> any TailnetConnection
}

/// A TCP connection that a peer opened to the node.
protocol TailnetConnection: Sendable {
    /// The peer's tailnet IP address, without a port.
    var remoteAddress: String? { get }
    /// The next bytes from the peer, or empty data when the peer closes the connection.
    /// Throws when no bytes arrive before the timeout.
    func receive(timeout: Duration) async throws -> Data
    /// Sends all the bytes, or throws.
    func send(_ data: Data, timeout: Duration) async throws
    func close() async
}

/// The node itself, once it's on the tailnet.
struct TailnetSelf: Equatable, Sendable {
    var stableID: String
    var userID: Int64
    var ipv4Address: String
    var ipv6Address: String?
    /// The MagicDNS name, without the trailing dot.
    var dnsName: String?
    var isTagged: Bool

    /// The names that clients can use for the node in the `Host` header.
    var hostNames: [String] {
        var names = [ipv4Address]
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
struct TailnetPeer: Equatable, Sendable {
    var stableID: String
    var deviceName: String
    var userID: Int64
    var isTagged: Bool
}

/// The parts of a node's status that iMCP reads.
struct TailnetStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case starting
        /// The node needs its owner to log in at the URL,
        /// once the control server provides one.
        case needsLogin(URL?)
        /// An admin of the tailnet must approve the node.
        case needsApproval
        case running(TailnetSelf)
        case stopped
    }

    var state: State
    /// The host names of the other nodes, by stable ID.
    var peerNames: [String: String] = [:]

    init(state: State, peerNames: [String: String] = [:]) {
        self.state = state
        self.peerNames = peerNames
    }

    /// Reads the JSON encoding of a node's `ipnstate.Status`.
    init(json data: Data) throws {
        struct Node: Decodable {
            var ID: String?
            var HostName: String?
            var DNSName: String?
            var TailscaleIPs: [String]?
            var UserID: Int64?
            var Tags: [String]?
        }
        struct Status: Decodable {
            var BackendState: String
            var AuthURL: String?
            var TailscaleIPs: [String]?
            var selfNode: Node?
            var Peer: [String: Node]?

            enum CodingKeys: String, CodingKey {
                case BackendState, AuthURL, TailscaleIPs, Peer
                case selfNode = "Self"
            }
        }

        let status = try JSONDecoder().decode(Status.self, from: data)
        for peer in (status.Peer ?? [:]).values {
            if let id = peer.ID, !id.isEmpty, let name = peer.HostName, !name.isEmpty {
                peerNames[id] = name
            }
        }

        switch status.BackendState {
        case "NeedsLogin":
            let url = status.AuthURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            state = .needsLogin(url)
        case "NeedsMachineAuth":
            state = .needsApproval
        case "Stopped":
            state = .stopped
        case "Running":
            let addresses = status.selfNode?.TailscaleIPs ?? status.TailscaleIPs ?? []
            guard let node = status.selfNode,
                let stableID = node.ID, !stableID.isEmpty,
                let userID = node.UserID, userID != 0,
                let ipv4 = addresses.first(where: { $0.contains(".") })
            else {
                state = .starting
                return
            }
            let dnsName = node.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            state = .running(
                TailnetSelf(
                    stableID: stableID,
                    userID: userID,
                    ipv4Address: ipv4,
                    ipv6Address: addresses.first { $0.contains(":") },
                    dnsName: dnsName?.isEmpty == false ? dnsName : nil,
                    isTagged: !(node.Tags ?? []).isEmpty
                )
            )
        default:
            state = .starting
        }
    }
}

// MARK: - Remote access server

/// Serves MCP over HTTP to the owner's other devices on their tailnet.
///
/// iMCP runs its own Tailscale node, so the server's address belongs only to iMCP.
/// The server listens only on that node's tailnet IPv4 address.
/// Each request must come from an untagged device
/// that belongs to the same Tailscale user as the node,
/// and must carry an access token.
/// Sessions follow the 2025-11-25 Streamable HTTP transport.
actor RemoteAccessServer {
    enum State: Equatable, Sendable {
        case off
        case starting
        /// The node needs its owner to log in at the URL,
        /// or is waiting for the control server to provide one.
        case needsLogin(URL?)
        /// An admin of the tailnet must approve the node.
        case needsApproval
        case running(Endpoint)
        case loggingOut
        case failed(String)
    }

    /// Where clients reach the server.
    struct Endpoint: Equatable, Sendable {
        var url: String
        /// The node's MagicDNS name.
        var dnsName: String?
        var ipv4Address: String
        var ipv6Address: String?
    }

    struct Configuration: Equatable, Sendable {
        var isEnabled: Bool
        var port: UInt16
        var hostname: String
    }

    static let defaultPort: UInt16 = 4627
    static let maximumConnections = 32
    static let maximumSessions = 16
    /// How long a session with no requests and no open streams lasts.
    static let sessionIdleTimeout: TimeInterval = 60 * 60
    /// How often iMCP reads the node's status while the node is on the tailnet.
    static let refreshInterval: Duration = .seconds(15)
    /// How often iMCP reads the node's status while it starts or waits for a login.
    static let startingRefreshInterval: Duration = .seconds(1)

    private struct Session {
        let tokenID: UUID
        /// The stable ID of the device that started the session.
        let deviceID: String
        let transport: StatefulHTTPServerTransport
        let server: MCP.Server
        var lastActivity: Date
        var openStreams: Int
    }

    private let tokenStore: AccessTokenStore
    private let stateDirectory: URL
    private let makeNode: @Sendable (TailnetNodeConfiguration) async throws -> any TailnetNode
    private let makeSessionServer: @Sendable (UUID) async -> MCP.Server?
    /// How long iMCP trusts a whois answer before it asks again.
    private let peerLifetime: TimeInterval

    private var configuration = Configuration(isEnabled: false, port: defaultPort, hostname: "")
    private var stateHandler: (@Sendable (State) -> Void)?
    private var tokenUsageHandler: (@Sendable () -> Void)?
    private var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.info("Remote access state: \(String(describing: self.state), privacy: .public)")
            stateHandler?(state)
        }
    }

    /// Counts node starts, so that work for a stopped node can tell that it's stale.
    private var generation = 0
    private var node: (any TailnetNode)?
    private var monitorTask: Task<Void, Never>?
    /// The node's identity, while the server listens on its address.
    private var identity: TailnetSelf?
    private var isListening = false
    private var connectionCount = 0
    private var peers: [String: (peer: TailnetPeer?, expires: Date)] = [:]
    private var sessions: [String: Session] = [:]

    init(
        tokenStore: AccessTokenStore,
        stateDirectory: URL,
        makeNode: @escaping @Sendable (TailnetNodeConfiguration) async throws -> any TailnetNode,
        makeSessionServer: @escaping @Sendable (UUID) async -> MCP.Server?,
        peerLifetime: TimeInterval = 60
    ) {
        self.tokenStore = tokenStore
        self.stateDirectory = stateDirectory
        self.makeNode = makeNode
        self.makeSessionServer = makeSessionServer
        self.peerLifetime = peerLifetime
    }

    func setHandlers(
        state: @escaping @Sendable (State) -> Void,
        tokenUsage: @escaping @Sendable () -> Void
    ) {
        stateHandler = state
        tokenUsageHandler = tokenUsage
        state(self.state)
    }

    /// Starts the node when remote access is on, and stops it when it's off.
    /// A change to the port or host name restarts the node.
    func configure(_ configuration: Configuration) async {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        guard configuration.isEnabled else {
            await stopNode()
            state = .off
            return
        }
        await startNode()
    }

    func stop() async {
        await configure(Configuration(isEnabled: false, port: configuration.port, hostname: configuration.hostname))
    }

    // MARK: Node

    /// Starts the node again with an auth key, which logs it in without a browser.
    func logIn(authKey: String) async {
        guard configuration.isEnabled else { return }
        await startNode(authKey: authKey)
    }

    /// Starts the node again, such as to get a new login URL.
    func restartNode() async {
        guard configuration.isEnabled else { return }
        await startNode()
    }

    /// Logs the node out of the tailnet and starts it again, ready for another login.
    func logOut() async {
        guard configuration.isEnabled, let node else { return }
        let current = generation
        state = .loggingOut
        await closeSessions { _ in true }
        do {
            try await node.logout()
        } catch {
            log.error("Couldn't log the remote access node out: \(error)")
            guard current == generation else { return }
            state = .failed("iMCP couldn't log out of Tailscale: \(error.localizedDescription)")
            return
        }
        // A new start asks the control server for a new login URL.
        guard current == generation else { return }
        await startNode()
    }

    private func startNode(authKey: String? = nil) async {
        await stopNode()
        guard configuration.port != 0 else {
            state = .failed("Choose a port from 1 to 65535.")
            return
        }
        state = .starting
        let current = generation
        let nodeConfiguration = TailnetNodeConfiguration(
            hostname: configuration.hostname,
            stateDirectory: stateDirectory,
            authKey: authKey
        )
        monitorTask = Task { [weak self] in
            await self?.runNode(nodeConfiguration, generation: current)
        }
    }

    private func stopNode() async {
        generation += 1
        monitorTask?.cancel()
        monitorTask = nil
        let node = self.node
        self.node = nil
        identity = nil
        isListening = false
        peers.removeAll()
        await closeSessions { _ in true }
        await node?.close()
    }

    private func runNode(_ nodeConfiguration: TailnetNodeConfiguration, generation current: Int) async {
        let node: any TailnetNode
        do {
            node = try await makeNode(nodeConfiguration)
        } catch {
            log.error("Remote access node failed to start: \(error)")
            guard current == generation else { return }
            state = .failed("iMCP couldn't start its Tailscale node: \(error.localizedDescription)")
            return
        }
        guard current == generation, !Task.isCancelled else {
            await node.close()
            return
        }
        self.node = node

        while current == generation, !Task.isCancelled {
            await refresh(node, generation: current)
            await revalidatePeers(node, generation: current)
            await closeIdleSessions()
            try? await Task.sleep(for: identity == nil ? Self.startingRefreshInterval : Self.refreshInterval)
        }
    }

    private func refresh(_ node: any TailnetNode, generation current: Int) async {
        let status: TailnetStatus
        do {
            status = try await node.status()
        } catch {
            log.error("Couldn't read the remote access node's status: \(error)")
            guard current == generation else { return }
            state = .failed("iMCP couldn't read its Tailscale node's status: \(error.localizedDescription)")
            return
        }
        guard current == generation, state != .loggingOut else { return }

        guard case .running(let me) = status.state else {
            if identity != nil {
                // The node left the tailnet, such as when its key expired.
                identity = nil
                peers.removeAll()
                await closeSessions { _ in true }
            }
            switch status.state {
            case .needsLogin(let url): state = .needsLogin(url)
            case .needsApproval: state = .needsApproval
            case .starting, .stopped, .running: state = .starting
            }
            return
        }

        guard !me.isTagged else {
            if identity != nil {
                identity = nil
                peers.removeAll()
                await closeSessions { _ in true }
            }
            state = .failed(
                "This node has tags, so iMCP can't tell which user owns it. Log out, then log in with your own account."
            )
            return
        }
        if let identity, identity != me {
            if identity.ipv4Address != me.ipv4Address {
                // The listener can't move to another address, so start over.
                await startNode()
                return
            }
            peers.removeAll()
            await closeSessions { _ in true }
        }
        identity = me

        if !isListening {
            do {
                let listener = try await node.listen(on: me.ipv4Address, port: configuration.port)
                guard current == generation else { return }
                isListening = true
                acceptConnections(from: listener, node: node, generation: current)
                log.notice("Remote access listening on \(me.ipv4Address, privacy: .public):\(self.configuration.port)")
            } catch {
                log.error("Remote access listener failed: \(error)")
                guard current == generation else { return }
                state = .failed("iMCP couldn't listen on port \(configuration.port): \(error.localizedDescription)")
                return
            }
        }

        let host = me.dnsName ?? me.ipv4Address
        state = .running(
            Endpoint(
                url: "http://\(host):\(configuration.port)/mcp",
                dnsName: me.dnsName,
                ipv4Address: me.ipv4Address,
                ipv6Address: me.ipv6Address
            )
        )
    }

    private func acceptConnections(
        from listener: any TailnetListener,
        node: any TailnetNode,
        generation current: Int
    ) {
        Task { [weak self] in
            while true {
                let connection: any TailnetConnection
                do {
                    connection = try await listener.accept()
                } catch {
                    break
                }
                guard let self else {
                    await connection.close()
                    return
                }
                await self.accept(connection, node: node, generation: current)
            }
            await self?.listenerEnded(generation: current)
        }
    }

    /// Lets the next refresh listen again if the node is still running.
    private func listenerEnded(generation current: Int) {
        guard current == generation else { return }
        isListening = false
    }

    // MARK: Connections

    private func accept(_ connection: any TailnetConnection, node: any TailnetNode, generation current: Int) async {
        guard current == generation, identity != nil, connectionCount < Self.maximumConnections,
            let address = connection.remoteAddress
        else {
            await connection.close()
            return
        }
        connectionCount += 1

        let http = HTTPServerConnection(connection)
        Task {
            await http.serve(
                { request in
                    // Check the device for each request,
                    // because its owner or tags can change while the connection is open.
                    guard let peer = await self.authorizedPeer(at: address, node: node, generation: current) else {
                        let error = MCPError.invalidRequest(
                            "Forbidden: Only devices that belong to the owner of this node can connect."
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

    /// Whether a peer may use the server:
    /// an untagged device that belongs to the same user as the node.
    static func isAuthorized(_ peer: TailnetPeer, for node: TailnetSelf) -> Bool {
        !node.isTagged && !peer.isTagged && !peer.stableID.isEmpty && peer.userID == node.userID
    }

    /// The device at an address, if it may use the server now.
    /// Returns `nil` if the node is stopped, changed, or not on the tailnet.
    /// When the answer changes, closes the sessions of the device that was there.
    private func authorizedPeer(at address: String, node: any TailnetNode, generation current: Int) async
        -> TailnetPeer?
    {
        guard current == generation, let identity else { return nil }
        let cached = peers[address]
        if let cached, cached.expires > Date() {
            return cached.peer
        }
        var authorized: TailnetPeer?
        var identified = true
        do {
            let peer = try await node.whois(address)
            if Self.isAuthorized(peer, for: identity) {
                authorized = peer
            } else {
                log.notice(
                    "Rejected remote request from \(address, privacy: .public): another user or a tagged device"
                )
            }
        } catch {
            log.error("Couldn't identify the remote device at \(address, privacy: .public): \(error)")
            identified = false
        }
        // Keep the decision only for the node that made it.
        guard current == generation, identity == self.identity else { return nil }
        // Don't keep a failed lookup, so that the next request asks again.
        peers[address] = identified ? (authorized, Date().addingTimeInterval(peerLifetime)) : nil
        if let previous = cached?.peer, previous.stableID != authorized?.stableID {
            await closeSessions { $0.deviceID == previous.stableID }
        }
        return authorized
    }

    /// Asks again about the devices whose answers expired,
    /// so that a device that loses access loses its open streams too.
    private func revalidatePeers(_ node: any TailnetNode, generation current: Int) async {
        let now = Date()
        for (address, entry) in peers where entry.expires <= now {
            if entry.peer == nil {
                peers.removeValue(forKey: address)
            } else {
                _ = await authorizedPeer(at: address, node: node, generation: current)
            }
        }
    }

    // MARK: Requests

    private var originValidator: OriginValidator {
        let port = configuration.port
        let hosts = identity?.hostNames ?? []
        return OriginValidator(
            allowedHosts: hosts.map { "\($0):\(port)" },
            allowedOrigins: hosts.map { "http://\($0):\(port)" }
        )
    }

    /// Logs a request without its body or credentials.
    private static func logRequest(
        _ request: HTTPRequestMessage,
        response: MCP.HTTPResponse,
        from peer: TailnetPeer
    ) {
        let method = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["method"] as? String
        log.info(
            "Remote request from \(peer.deviceName, privacy: .public): \(request.method, privacy: .public) \(request.path, privacy: .public) \(method ?? "-", privacy: .public), session \(request.header(HTTPHeaderName.sessionID) == nil ? "none" : "set", privacy: .public), token \(request.header(HTTPHeaderName.authorization) == nil ? "none" : "set", privacy: .public), accept \(request.header("Accept") ?? "-", privacy: .public) -> \(response.statusCode)"
        )
    }

    func respond(to message: HTTPRequestMessage, from peer: TailnetPeer) async -> MCP.HTTPResponse {
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
            return Self.unauthorizedResponse
        }
        if let bound = token.boundDevice, bound.stableID != peer.stableID {
            return Self.rejectDevice(peer)
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
        peer: TailnetPeer
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
        guard let server = await makeSessionServer(token.id) else {
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
        let tokenID = token.id
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
        do {
            try tokenStore.bind(token, to: .init(stableID: peer.stableID, name: peer.deviceName))
        } catch {
            await server.stop()
            switch error {
            case AccessTokenStore.BindingError.differentDevice:
                return Self.rejectDevice(peer)
            case is AccessTokenStore.StorageError:
                // A binding that isn't saved could let another device claim the token later.
                log.error("Couldn't save a remote access token's device: \(error)")
                return .error(statusCode: 503, .internalError("Service Unavailable: iMCP couldn't save the token."))
            default:
                return Self.unauthorizedResponse
            }
        }
        var openStreams = 0
        if case .stream = response { openStreams = 1 }
        sessions[sessionID] = Session(
            tokenID: tokenID,
            deviceID: peer.stableID,
            transport: transport,
            server: server,
            lastActivity: Date(),
            openStreams: openStreams
        )
        tokenUsageHandler?()
        log.notice(
            "Remote session started with token \(token.name, privacy: .public) from \(peer.deviceName, privacy: .public)"
        )
        return response
    }

    private static var unauthorizedResponse: MCP.HTTPResponse {
        .error(
            statusCode: 401,
            .invalidRequest("Unauthorized: Send an iMCP access token in the Authorization header."),
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: #"Bearer realm="iMCP""#]
        )
    }

    private static func rejectDevice(_ peer: TailnetPeer) -> MCP.HTTPResponse {
        log.notice(
            "Rejected remote request from \(peer.deviceName, privacy: .public), node \(peer.stableID, privacy: .public): access token is bound to another device"
        )
        return .error(statusCode: 403, .invalidRequest("Forbidden: This access token is bound to another device."))
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

    // MARK: Host name

    /// A host name for the node, made from the Mac's name,
    /// such as `mattts-macbook-pro-imcp` for "Mattt's MacBook Pro".
    static func defaultHostname(computerName: String?) -> String {
        sanitizedHostname("\(computerName ?? "Mac") iMCP") ?? "imcp"
    }

    /// A DNS label made from a name, or `nil` if the name has no letters or digits.
    static func sanitizedHostname(_ name: String) -> String? {
        var label = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                label.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else if !label.isEmpty, label.last != "-" {
                label.append("-")
            }
        }
        while label.last == "-" { label.removeLast() }
        label = String(label.prefix(63))
        while label.last == "-" { label.removeLast() }
        return label.isEmpty ? nil : label
    }
}

// MARK: - HTTP connection

/// One client connection to the remote access server.
/// It reads a request, writes the response, and repeats while the client keeps the connection open.
final class HTTPServerConnection: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestMessage) async -> (MCP.HTTPResponse, keepAlive: Bool)

    /// How long a connection can wait for a request.
    static let idleTimeout: Duration = .seconds(120)
    /// How long the peer has to accept each write.
    static let sendTimeout: Duration = .seconds(30)
    /// How often an open event stream gets a comment, so that a closed connection is noticed.
    static let keepAliveInterval: Duration = .seconds(25)

    private let connection: any TailnetConnection
    // Only `serve(_:streamEnded:)` reads and writes the buffer, one request at a time.
    private var buffer = Data()

    init(_ connection: any TailnetConnection) {
        self.connection = connection
    }

    /// Serves requests until the client or the handler ends the connection, then closes it.
    func serve(_ handler: Handler, streamEnded: @Sendable (String?) async -> Void) async {
        await serveRequests(handler, streamEnded: streamEnded)
        // No read is in progress here, so closing can't affect a reused descriptor.
        await connection.close()
    }

    private func serveRequests(_ handler: Handler, streamEnded: @Sendable (String?) async -> Void) async {
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

    /// The next request, or `nil` when the connection closes or waits too long.
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
        guard let data = try? await connection.receive(timeout: Self.idleTimeout), !data.isEmpty else {
            return nil
        }
        return data
    }

    private func send(_ data: Data) async -> Bool {
        do {
            try await connection.send(data, timeout: Self.sendTimeout)
            return true
        } catch {
            return false
        }
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
