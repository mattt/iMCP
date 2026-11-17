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
    /// Publishes the node on the internet through Tailscale Funnel,
    /// forwarding HTTPS connections to `127.0.0.1` at the port.
    /// Returns the node's public host name.
    func enableFunnel(localPort: UInt16) async throws -> String
    /// Stops Funnel and clears its saved configuration.
    func disableFunnel() async throws
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
protocol TailnetConnection: MobileByteStream {
    /// The peer's tailnet IP address, without a port.
    var remoteAddress: String? { get }
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
///
/// When public access is on, the node also serves the internet through Tailscale Funnel.
/// Funnel forwards each request to a listener on 127.0.0.1,
/// which can't tell who sent it, so those requests get none of the tailnet's trust.
/// See `FunnelPolicy`.
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

        /// The state's name without its values,
        /// so that logs don't include a login URL or an error message.
        var name: String {
            switch self {
            case .off: "off"
            case .starting: "starting"
            case .needsLogin: "needsLogin"
            case .needsApproval: "needsApproval"
            case .running: "running"
            case .loggingOut: "loggingOut"
            case .failed: "failed"
            }
        }
    }

    /// Where clients reach the server.
    struct Endpoint: Equatable, Sendable {
        var url: String
        /// The node's MagicDNS name.
        var dnsName: String?
        var ipv4Address: String
        var ipv6Address: String?
        var funnel: Funnel = .off
        /// The public WebSocket URL for iMCP for iOS when Funnel is active.
        var mobileWebSocketURL: String? = nil
    }

    /// Whether the server is open to the internet.
    enum Funnel: Equatable, Sendable {
        case off
        /// The URL that anyone on the internet can use, with a token.
        case active(url: String)
        /// Funnel didn't start. The tailnet server keeps running.
        case failed(String)
    }

    struct Configuration: Equatable, Sendable {
        var isEnabled: Bool
        var port: UInt16
        var hostname: String
        /// Whether to also serve the internet through Tailscale Funnel.
        var funnelEnabled = false
        /// Optional TCP port on the tailnet address for direct iPhone/iPad connections.
        var mobilePort: UInt16? = nil
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
        let deviceID: String?
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
    private let makeLocalListener: @Sendable () async throws -> any LocalForwardListener
    /// The OAuth authorization server for public access.
    private let oauthEndpoints: OAuthEndpoints

    private var configuration = Configuration(isEnabled: false, port: defaultPort, hostname: "")
    private var stateHandler: (@Sendable (State) -> Void)?
    private var tokenUsageHandler: (@Sendable () -> Void)?
    private var mobileTCPHandler: (@Sendable (any TailnetConnection) async -> Void)?
    private var mobileWebSocketHandler: (@Sendable (any MobileFrameWire) async -> Void)?
    private var isMobileListening = false
    private var mobileConnections: [UUID: Task<Void, Never>] = [:]
    private var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.info("Remote access state: \(self.state.name, privacy: .public)")
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
    /// The tasks that serve open connections.
    private var connections: [UUID: Task<Void, Never>] = [:]
    /// The tasks that serve connections that came through Funnel.
    private var funnelConnections: [UUID: Task<Void, Never>] = [:]
    private var funnelListener: (any LocalForwardListener)?
    /// The node's public name, while Funnel is on.
    private var funnelHost: String?
    private var funnelState: Funnel = .off
    /// Whether this node start already turned Funnel on or decided not to.
    private var funnelConfigured = false
    /// Whether this node start already cleared the Funnel configuration that an earlier run left.
    private var funnelCleared = false
    /// Whether this node start asked for Funnel, so that a later stop clears what the request may have saved.
    private var funnelRequested = false
    /// The request to turn Funnel on, while it's in flight.
    private var funnelEnableTask: Task<String, any Error>?
    private var failedAuth = FailedAuthLimiter()
    private var peers: [String: (peer: TailnetPeer?, expires: Date)] = [:]
    private var sessions: [String: Session] = [:]
    /// Counts the times that every session closed,
    /// so that a session that was starting then can tell that it's stale.
    private var sessionEpoch = 0
    /// Sessions that are starting, which count toward the session limit.
    private var pendingSessions = 0

    init(
        tokenStore: AccessTokenStore,
        stateDirectory: URL,
        makeNode: @escaping @Sendable (TailnetNodeConfiguration) async throws -> any TailnetNode,
        makeSessionServer: @escaping @Sendable (UUID) async -> MCP.Server?,
        peerLifetime: TimeInterval = 60,
        makeLocalListener: @escaping @Sendable () async throws -> any LocalForwardListener = {
            try await LoopbackListener.start()
        },
        oauth: OAuthAuthority = .shared
    ) {
        self.oauthEndpoints = OAuthEndpoints(authority: oauth)
        self.tokenStore = tokenStore
        self.stateDirectory = stateDirectory
        self.makeNode = makeNode
        self.makeSessionServer = makeSessionServer
        self.peerLifetime = peerLifetime
        self.makeLocalListener = makeLocalListener
    }

    func setHandlers(
        state: @escaping @Sendable (State) -> Void,
        tokenUsage: @escaping @Sendable () -> Void
    ) {
        stateHandler = state
        tokenUsageHandler = tokenUsage
        state(self.state)
    }

    /// Sets how iMCP asks its owner to approve an app that wants public access through OAuth.
    func setOAuthApprovalHandler(_ handler: OAuthEndpoints.ApprovalHandler?) {
        oauthEndpoints.setApprovalHandler(handler)
    }

    /// Sets the handlers for iPhone/iPad connections over Tailscale VPN and Tailscale Funnel WebSockets.
    func setMobileHandlers(
        tcp: (@Sendable (any TailnetConnection) async -> Void)?,
        webSocket: (@Sendable (any MobileFrameWire) async -> Void)?
    ) {
        mobileTCPHandler = tcp
        mobileWebSocketHandler = webSocket
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
        var off = configuration
        off.isEnabled = false
        await configure(off)
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
        await closeAllSessions()
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
        isMobileListening = false
        peers.removeAll()
        // A cancelled connection ends its stream and handles no more requests.
        // Each task closes its own connection, because closing it during a read isn't safe.
        for task in connections.values { task.cancel() }
        for task in mobileConnections.values { task.cancel() }
        for task in funnelConnections.values { task.cancel() }
        funnelListener?.shutdown()
        funnelListener = nil
        // A request in flight can still save its configuration, so let it finish before clearing.
        if let pending = funnelEnableTask {
            _ = try? await pending.value
        }
        let hadFunnel = funnelHost != nil || funnelRequested
        funnelHost = nil
        funnelState = .off
        funnelConfigured = false
        funnelCleared = false
        funnelRequested = false
        failedAuth = FailedAuthLimiter()
        await closeAllSessions()
        if hadFunnel {
            // Funnel's configuration is saved with the node, so clear it,
            // or the public name would keep forwarding to a port that another process could take.
            await clearFunnel(node)
        }
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
                await closeAllSessions()
            }
            switch status.state {
            case .needsLogin(let url): state = .needsLogin(url)
            case .needsApproval: state = .needsApproval
            case .starting, .stopped, .running: state = .starting
            }
            return
        }

        // An earlier run may have left Funnel on. Clear it before anything can return early.
        if !funnelCleared {
            funnelCleared = true
            await clearFunnel(node)
            guard current == generation else { return }
        }

        guard !me.isTagged else {
            if identity != nil {
                identity = nil
                peers.removeAll()
                await closeAllSessions()
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
            await closeAllSessions()
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

        if !isMobileListening, let mobilePort = configuration.mobilePort, mobilePort > 0, mobileTCPHandler != nil {
            do {
                let mobileListener = try await node.listen(on: me.ipv4Address, port: mobilePort)
                guard current == generation else { return }
                isMobileListening = true
                acceptMobileConnections(from: mobileListener, node: node, generation: current)
                log.notice("Mobile tailnet listener active on \(me.ipv4Address, privacy: .public):\(mobilePort)")
            } catch {
                log.error("Mobile tailnet listener failed: \(error)")
            }
        }

        if !funnelConfigured {
            funnelConfigured = true
            if configuration.funnelEnabled {
                await startFunnel(node, generation: current)
                guard current == generation else { return }
            }
        }

        let host = me.dnsName ?? me.ipv4Address
        state = .running(
            Endpoint(
                url: "http://\(host):\(configuration.port)/mcp",
                dnsName: me.dnsName,
                ipv4Address: me.ipv4Address,
                ipv6Address: me.ipv6Address,
                funnel: funnelState,
                mobileWebSocketURL: funnelHost.map(FunnelPolicy.mobileWebSocketURL(host:))
            )
        )
    }

    // MARK: Funnel

    /// Listens on 127.0.0.1 and asks Tailscale to forward public HTTPS connections to it.
    private func startFunnel(_ node: any TailnetNode, generation current: Int) async {
        let local: any LocalForwardListener
        do {
            local = try await makeLocalListener()
        } catch {
            log.error("Public access listener failed: \(error)")
            guard current == generation else { return }
            funnelState = .failed("iMCP couldn't listen for public connections: \(error.localizedDescription)")
            return
        }
        guard current == generation else {
            local.shutdown()
            return
        }
        funnelListener = local
        // Accept first, so that no public request meets a closed port.
        acceptFunnelConnections(from: local, generation: current)
        funnelRequested = true
        let port = local.port
        let enable = Task { try await node.enableFunnel(localPort: port) }
        funnelEnableTask = enable
        defer { funnelEnableTask = nil }
        do {
            let host = FunnelPolicy.normalizedHost(try await enable.value)
            guard current == generation else { return }
            funnelHost = host
            funnelState = .active(url: FunnelPolicy.publicURL(host: host))
            log.notice("Public access is on")
        } catch {
            log.error("Couldn't turn on Funnel: \(error)")
            guard current == generation else { return }
            local.shutdown()
            funnelListener = nil
            funnelState = .failed("Tailscale didn't turn on Funnel: \(error.localizedDescription)")
        }
    }

    private func clearFunnel(_ node: (any TailnetNode)?) async {
        do {
            try await node?.disableFunnel()
        } catch {
            log.error("Couldn't clear Funnel: \(error)")
        }
    }

    private func acceptFunnelConnections(from listener: any LocalForwardListener, generation current: Int) {
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
                await self.acceptFunnel(connection, generation: current)
            }
        }
    }

    private func acceptFunnel(_ connection: any TailnetConnection, generation current: Int) async {
        guard current == generation, funnelHost != nil, funnelConnections.count < FunnelPolicy.maximumConnections
        else {
            await connection.close()
            return
        }
        let id = UUID()
        let http = HTTPServerConnection(
            connection,
            limits: .publicInternet,
            idleTimeout: FunnelPolicy.idleTimeout,
            requestDeadline: FunnelPolicy.requestDeadline
        )
        funnelConnections[id] = Task {
            await http.serve(
                { request in
                    let response = await self.respondPublic(to: request)
                    Self.logPublicRequest(request, statusCode: response.statusCode)
                    return (response, keepAlive: !FunnelPolicy.closesConnection(afterStatus: response.statusCode))
                },
                onUpgrade: { message, rawConnection, leftover in
                    await self.handleFunnelMobileUpgrade(
                        message: message,
                        connection: rawConnection,
                        leftover: leftover
                    )
                },
                streamEnded: { sessionID in await self.streamEnded(sessionID: sessionID) }
            )
            self.funnelConnectionClosed(id)
        }
    }

    private func handleFunnelMobileUpgrade(
        message: HTTPRequestMessage,
        connection: any TailnetConnection,
        leftover: Data
    ) async -> Bool {
        guard message.path == MobileLink.mobileWebSocketPath,
            MobileWebSocketHandshake.isUpgradeRequest(method: message.method, headers: message.headers)
        else {
            return false
        }
        guard let host = funnelHost else {
            let reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try? await connection.send(Data(reply.utf8), timeout: .seconds(5))
            await connection.close()
            return true
        }
        let validator = FunnelPolicy.originValidator(host: host)
        let request = MCP.HTTPRequest(
            method: message.method,
            headers: message.headers,
            body: nil,
            path: message.path
        )
        let context = HTTPValidationContext(
            httpMethod: message.method,
            sessionID: nil,
            isInitializationRequest: false,
            supportedProtocolVersions: MCP.Version.supported
        )
        if validator.validate(request, context: context) != nil {
            let reply = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try? await connection.send(Data(reply.utf8), timeout: .seconds(5))
            await connection.close()
            return true
        }
        guard let handler = mobileWebSocketHandler,
            let clientKey = MobileWebSocketHandshake.header("Sec-WebSocket-Key", in: message.headers)
        else {
            let reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try? await connection.send(Data(reply.utf8), timeout: .seconds(5))
            await connection.close()
            return true
        }
        do {
            try await connection.send(
                MobileWebSocketHandshake.responseData(clientKey: clientKey),
                timeout: .seconds(5)
            )
        } catch {
            await connection.close()
            return true
        }
        let wire = MobileServerWebSocketWire(stream: connection, initialBuffer: leftover)
        await handler(wire)
        return true
    }

    private func funnelConnectionClosed(_ id: UUID) {
        funnelConnections.removeValue(forKey: id)
    }

    private func acceptMobileConnections(
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
                await self.acceptMobile(connection, node: node, generation: current)
            }
            await self?.mobileListenerEnded(generation: current)
        }
    }

    private func mobileListenerEnded(generation current: Int) {
        guard current == generation else { return }
        isMobileListening = false
    }

    private func acceptMobile(_ connection: any TailnetConnection, node: any TailnetNode, generation current: Int) async {
        guard current == generation,
            identity != nil,
            mobileConnections.count < Self.maximumConnections,
            let address = connection.remoteAddress,
            let handler = mobileTCPHandler
        else {
            await connection.close()
            return
        }
        guard await authorizedPeer(at: address, node: node, generation: current) != nil else {
            await connection.close()
            return
        }
        let id = UUID()
        mobileConnections[id] = Task {
            await handler(connection)
            self.mobileConnectionClosed(id)
        }
    }

    private func mobileConnectionClosed(_ id: UUID) {
        mobileConnections.removeValue(forKey: id)
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
        guard current == generation, identity != nil, connections.count < Self.maximumConnections,
            let address = connection.remoteAddress
        else {
            await connection.close()
            return
        }
        let id = UUID()
        let http = HTTPServerConnection(connection)
        connections[id] = Task {
            await http.serve(
                { request in
                    // Check the device for each request,
                    // because its owner or tags can change while the connection is open.
                    guard let peer = await self.authorizedPeer(at: address, node: node, generation: current) else {
                        let error = MCPError.invalidRequest(
                            "Forbidden: Only devices that belong to the owner of this node can connect."
                        )
                        return (ServedResponse.mcp(.error(statusCode: 403, error)), keepAlive: false)
                    }
                    let response = await self.respond(to: request, from: peer)
                    Self.logRequest(request, response: response, from: peer)
                    return (.mcp(response), keepAlive: true)
                },
                streamEnded: { sessionID in await self.streamEnded(sessionID: sessionID) }
            )
            self.connectionClosed(id)
        }
    }

    private func connectionClosed(_ id: UUID) {
        connections.removeValue(forKey: id)
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

    /// Logs a request that came through Funnel, without its body, credentials, or address.
    private static func logPublicRequest(_ request: HTTPRequestMessage, statusCode: Int) {
        log.info(
            "Public request: \(request.method, privacy: .public) \(request.path, privacy: .public), token \(request.header(HTTPHeaderName.authorization) == nil ? "none" : "set", privacy: .public) -> \(statusCode)"
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
        return await continueRequest(
            message,
            request,
            caller: Caller(id: token.id, name: token.name, token: token),
            peer: peer,
            validator: originValidator
        )
    }

    /// Whether Funnel is on, for tests.
    var hasFunnelHost: Bool { funnelHost != nil }

    /// Answers a request that came through Funnel.
    ///
    /// The request is internet traffic, whatever its address says.
    /// The OAuth paths come first, because they are how an app gets a token,
    /// and they need none. Everything else needs an access token that isn't bound to a tailnet device,
    /// or an OAuth access token issued for this endpoint.
    /// The `Host` and `Origin` must name the node's public name for every path.
    func respondPublic(to message: HTTPRequestMessage) async -> ServedResponse {
        guard let host = funnelHost else { return .mcp(Self.unavailableResponse) }
        let validator = FunnelPolicy.originValidator(host: host)
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

        if OAuthEndpoints.handles(path: message.path) {
            // A browser's top-level navigation and a server-side client send no `Origin`,
            // and a page on another site does, so the check stops cross-site requests from browsers.
            if let rejection = validator.validate(request, context: context) {
                return .mcp(rejection)
            }
            return await oauthEndpoints.handle(message, host: host)
        }

        let resource = FunnelPolicy.publicURL(host: host)
        let oauth = oauthEndpoints.authority
        let decision = FunnelPolicy.authorize(
            authorizationField: message.header(HTTPHeaderName.authorization),
            lookup: tokenStore.token(secret:),
            oauthLookup: { oauth.authenticate(accessToken: $0, resource: resource) },
            limiter: &failedAuth
        )
        let caller: Caller
        switch decision {
        case .allowed(let allowed):
            caller = Caller(id: allowed.id, name: allowed.name, token: allowed)
        case .allowedOAuth(let grant):
            caller = Caller(id: grant.id, name: grant.clientName, token: nil)
        case .unauthorized:
            return .mcp(
                Self.publicUnauthorizedResponse(
                    host: host,
                    presentedToken: message.header(HTTPHeaderName.authorization) != nil
                )
            )
        case .rateLimited(let retryAfter):
            return .mcp(
                .error(
                    statusCode: 429,
                    .invalidRequest("Too Many Requests: Try again later."),
                    extraHeaders: ["Retry-After": String(retryAfter)]
                )
            )
        case .boundToDevice:
            return .mcp(
                .error(
                    statusCode: 403,
                    .invalidRequest(
                        "Forbidden: This access token belongs to a device on the tailnet. Create a token for public access."
                    )
                )
            )
        }
        guard message.path == "/mcp" else {
            return .mcp(.error(statusCode: 404, .invalidRequest("Not Found: The MCP endpoint is /mcp.")))
        }
        if let rejection = validator.validate(request, context: context) {
            return .mcp(rejection)
        }
        return .mcp(await continueRequest(message, request, caller: caller, peer: nil, validator: validator))
    }

    /// The `401` for a request through Funnel.
    /// It points clients to the protected resource metadata, so that an OAuth client can find the way to get a token.
    static func publicUnauthorizedResponse(host: String, presentedToken: Bool) -> MCP.HTTPResponse {
        var challenge = #"Bearer realm="iMCP""#
        if presentedToken { challenge += #", error="invalid_token""# }
        challenge +=
            #", resource_metadata="\#(OAuthEndpoints.resourceMetadataURL(host: host))", scope="\#(OAuthAuthority.scope)""#
        return .error(
            statusCode: 401,
            .invalidRequest("Unauthorized: Send an access token in the Authorization header."),
            extraHeaders: [HTTPHeaderName.wwwAuthenticate: challenge]
        )
    }

    /// Who is calling: an access token, or an OAuth grant.
    private struct Caller {
        var id: UUID
        var name: String
        /// The access token, which a tailnet device can bind itself to. `nil` for an OAuth grant.
        var token: AccessToken?
    }

    /// Handles a request whose token and origin are checked.
    /// `peer` is `nil` for a request that came through Funnel.
    private func continueRequest(
        _ message: HTTPRequestMessage,
        _ request: MCP.HTTPRequest,
        caller: Caller,
        peer: TailnetPeer?,
        validator: OriginValidator
    ) async -> MCP.HTTPResponse {
        if let sessionID = request.header(HTTPHeaderName.sessionID) {
            // A session belongs to the token that started it.
            guard var session = sessions[sessionID], session.tokenID == caller.id else {
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
        return await startSession(with: request, caller: caller, peer: peer, validator: validator)
    }

    private func startSession(
        with request: MCP.HTTPRequest,
        caller: Caller,
        peer: TailnetPeer?,
        validator: OriginValidator
    ) async -> MCP.HTTPResponse {
        // Each wait below can outlast a shutdown or a change of node,
        // so check the epoch after each one.
        let epoch = sessionEpoch
        // Reserve a slot first, so that concurrent starts can't exceed the limit.
        pendingSessions += 1
        defer { pendingSessions -= 1 }
        if sessions.count + pendingSessions > Self.maximumSessions {
            // Make room by ending the session that has waited longest without a request or stream.
            if let oldest = sessions.values.filter({ $0.openStreams == 0 })
                .min(by: { $0.lastActivity < $1.lastActivity })
            {
                await closeSessions { $0.transport === oldest.transport }
            } else {
                return .error(statusCode: 503, .internalError("Service Unavailable: Too many sessions."))
            }
        }
        guard epoch == sessionEpoch, let server = await makeSessionServer(caller.id), epoch == sessionEpoch else {
            return Self.unavailableResponse
        }

        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                validator,
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ])
        )
        let tokenID = caller.id
        do {
            try await server.start(transport: transport)
        } catch {
            log.error("Couldn't start a remote session: \(error)")
            return .error(statusCode: 500, .internalError("Internal error: The session couldn't start."))
        }
        guard epoch == sessionEpoch else {
            await server.stop()
            return Self.unavailableResponse
        }

        let response = await transport.handleRequest(request)
        guard epoch == sessionEpoch else {
            await transport.disconnect()
            await server.stop()
            return Self.unavailableResponse
        }
        guard let sessionID = response.headers[HTTPHeaderName.sessionID] else {
            await server.stop()
            return response
        }
        do {
            // A request through Funnel has no device to bind the token to.
            if let peer, let token = caller.token {
                try tokenStore.bind(token, to: .init(stableID: peer.stableID, name: peer.deviceName))
            }
        } catch {
            await server.stop()
            switch error {
            case AccessTokenStore.BindingError.differentDevice:
                return peer.map(Self.rejectDevice) ?? Self.unauthorizedResponse
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
            deviceID: peer?.stableID,
            transport: transport,
            server: server,
            lastActivity: Date(),
            openStreams: openStreams
        )
        tokenUsageHandler?()
        log.notice(
            "Remote session started with token \(caller.name, privacy: .public) from \(peer?.deviceName ?? "the internet", privacy: .public)"
        )
        return response
    }

    private static var unavailableResponse: MCP.HTTPResponse {
        .error(statusCode: 503, .internalError("Service Unavailable"))
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

    /// Closes every session, including the ones that are starting.
    private func closeAllSessions() async {
        sessionEpoch += 1
        await closeSessions { _ in true }
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
        FunnelPolicy.bearerToken(in: request.header(HTTPHeaderName.authorization))
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
    typealias Handler = @Sendable (HTTPRequestMessage) async -> (ServedResponse, keepAlive: Bool)

    /// How long a connection can wait for a request.
    static let idleTimeout: Duration = .seconds(120)
    /// How long the peer has to accept each write.
    static let sendTimeout: Duration = .seconds(30)
    /// How often an open event stream gets a comment, so that a closed connection is noticed.
    static let keepAliveInterval: Duration = .seconds(25)

    private let connection: any TailnetConnection
    private let limits: HTTPRequestParser.Limits
    private let idleTimeout: Duration
    /// How long a request can take to arrive in full, from its first byte.
    /// Without it, a client that sends one byte at a time keeps the connection for as long as it likes.
    private let requestDeadline: Duration?
    // Only `serve(_:streamEnded:)` reads and writes the buffer, one request at a time.
    private var buffer = Data()

    init(
        _ connection: any TailnetConnection,
        limits: HTTPRequestParser.Limits = .tailnet,
        idleTimeout: Duration = HTTPServerConnection.idleTimeout,
        requestDeadline: Duration? = nil
    ) {
        self.connection = connection
        self.limits = limits
        self.idleTimeout = idleTimeout
        self.requestDeadline = requestDeadline
    }

    typealias UpgradeHandler = @Sendable (HTTPRequestMessage, any TailnetConnection, Data) async -> Bool

    /// Serves requests until the client or the handler ends the connection, then closes it.
    func serve(
        _ handler: Handler,
        onUpgrade: UpgradeHandler? = nil,
        streamEnded: @Sendable (String?) async -> Void
    ) async {
        let upgraded = await serveRequests(handler, onUpgrade: onUpgrade, streamEnded: streamEnded)
        if !upgraded {
            // No read is in progress here, so closing can't affect a reused descriptor.
            await connection.close()
        }
    }

    private func serveRequests(
        _ handler: Handler,
        onUpgrade: UpgradeHandler?,
        streamEnded: @Sendable (String?) async -> Void
    ) async -> Bool {
        while let result = await readRequest() {
            // The server cancels the connection when it stops.
            guard !Task.isCancelled else { return false }
            switch result {
            case .request(let message, _):
                if let onUpgrade, await onUpgrade(message, connection, buffer) {
                    return true
                }
                let (response, keepAlive) = await handler(message)
                let shouldKeepAlive = keepAlive && message.keepAlive
                let sent = await write(response, keepAlive: shouldKeepAlive, streamEnded: streamEnded)
                guard sent, shouldKeepAlive else { return false }
            case .failure(let status, let reason):
                _ = await write(
                    .mcp(.error(statusCode: status, .invalidRequest(reason))),
                    keepAlive: false,
                    streamEnded: streamEnded
                )
                return false
            case .incomplete:
                return false
            }
        }
        return false
    }

    /// The next request, or `nil` when the connection closes or waits too long.
    private func readRequest() async -> HTTPRequestParser.Result? {
        var sentContinue = false
        // When the request's first byte arrived. Bytes left over from the last read count as arrived.
        var firstByte: ContinuousClock.Instant? = buffer.isEmpty ? nil : .now
        while true {
            let result = HTTPRequestParser.parse(buffer, limits: limits)
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
                var timeout = idleTimeout
                if let requestDeadline, let firstByte {
                    let remaining = requestDeadline - (.now - firstByte)
                    // The request took too long. Close the connection.
                    guard remaining > .zero else { return nil }
                    timeout = min(timeout, remaining)
                }
                guard let data = await receive(timeout: timeout) else { return nil }
                firstByte = firstByte ?? .now
                buffer.append(data)
            }
        }
    }

    private func receive(timeout: Duration) async -> Data? {
        guard let data = try? await connection.receive(timeout: timeout), !data.isEmpty else {
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
        _ served: ServedResponse,
        keepAlive: Bool,
        streamEnded: @Sendable (String?) async -> Void
    ) async -> Bool {
        let response: MCP.HTTPResponse
        switch served {
        case .mcp(let mcp):
            response = mcp
        case .raw(let status, let headers, let body):
            var data = HTTPResponseEncoder.head(
                status: status,
                headers: headers,
                contentLength: body.count,
                keepAlive: keepAlive
            )
            data.append(body)
            return await send(data)
        }
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
