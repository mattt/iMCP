import CryptoKit
import Foundation
import MCP
import Network
import OSLog
import Ontology

/// Serves the Home tools over TLS with the pairing key as a pre-shared key,
/// or, until the helper is paired, accepts one pairing request
/// over TLS with a key derived from the one-time code.
actor HelperServer {
    /// What the listener's TLS pre-shared key comes from.
    enum Credential: Sendable {
        /// The one-time code that the helper shows until it is paired.
        case code(String)
        /// The key that iMCP sent when it paired.
        case key(SymmetricKey)
    }

    /// Changes that the helper's window applies.
    enum Event: Sendable {
        /// iMCP sent a key over a pairing connection with `code`, and that connection ended.
        case paired(SymmetricKey, code: String)
        /// Too many pairing handshakes with `code` failed, so the code must be replaced.
        case tooManyFailedPairings(code: String)
    }

    /// A pairing that a connection started by sending a key.
    private struct Pairing {
        let id = UUID()
        let session: UUID
        let key: SymmetricKey
        let code: String
        /// Whether the helper stored the key, so the response can say so.
        var stored = false
        /// Whether the `paired` event was sent.
        var reported = false
    }

    private let backend: any HomeBackend
    private let storeKey: @Sendable (SymmetricKey, _ code: String) async throws -> Void
    private let onEvent: @Sendable (Event) async -> Void
    private let willStartSession: @Sendable () async -> Void
    private var credential: Credential
    private var listener: NWListener?
    private var sessions: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var failedPairings = 0
    /// Set when a pairing connection sends a key, so the code works only once.
    private var pairing: Pairing?
    private let log = Logger.service("helper.server")

    /// Creates a server.
    /// `storeKey` keeps a key from pairing before the helper acknowledges it,
    /// and `onEvent` reports changes for the window to apply.
    /// `willStartSession` runs where a session can be suspended before it starts;
    /// tests use it to restart the server at that point.
    init(
        backend: any HomeBackend,
        credential: Credential,
        storeKey: @escaping @Sendable (SymmetricKey, _ code: String) async throws -> Void = { _, _ in },
        onEvent: @escaping @Sendable (Event) async -> Void = { _ in },
        willStartSession: @escaping @Sendable () async -> Void = {}
    ) {
        self.backend = backend
        self.credential = credential
        self.storeKey = storeKey
        self.onEvent = onEvent
        self.willStartSession = willStartSession
    }

    /// Listens on an ephemeral loopback port and returns the port.
    /// The helper's window applies one change at a time, so calls don't overlap.
    func start() async throws -> NWEndpoint.Port {
        if let port = listener?.port { return port }
        return try await listen()
    }

    private func listen() async throws -> NWEndpoint.Port {
        let parameters =
            switch credential {
            case .code(let code): try HomeHelperPairing.pairingParameters(code: code)
            case .key(let key): HomeHelperPairing.parameters(key: key)
            }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { await self?.accept(connection, from: listener) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { await self?.stateChanged(state, of: listener) }
        }
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.start(queue: .main)
            Task { [weak self, weak listener] in
                try? await Task.sleep(for: .seconds(10))
                await self?.startupTimedOut(listener)
            }
        }
        // A restart while this listener started replaced it.
        guard listener === self.listener else { throw CancellationError() }
        guard let port = listener.port else { throw HomeError("iMCP Helper has no TCP port.") }
        return port
    }

    /// Ends every session, including any in its TLS handshake,
    /// and listens again with a new credential.
    /// Returns the new port.
    ///
    /// Tool calls that a session already accepted can still finish:
    /// swift-sdk's `Server.stop()` doesn't cancel request handlers,
    /// and HomeKit mutations with several steps don't check the session between steps.
    func restart(credential: Credential) async throws -> NWEndpoint.Port {
        stop()
        self.credential = credential
        failedPairings = 0
        pairing = nil
        return try await start()
    }

    /// Stops listening and ends every session, including any in its TLS handshake.
    func stop() {
        stopListening()
        for connection in sessions.values { connection.cancel() }
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        startup?.resume(throwing: CancellationError())
        startup = nil
    }

    private func stateChanged(_ state: NWListener.State, of changed: NWListener?) {
        // Ignore a listener that a restart replaced.
        guard let changed, changed === listener else { return }
        switch state {
        case .ready:
            startup?.resume()
            startup = nil
        case .failed(let error):
            startup?.resume(throwing: error)
            startup = nil
            listener?.cancel()
            listener = nil
            log.error("Home listener failed: \(error.localizedDescription)")
        default: break
        }
    }

    private func startupTimedOut(_ timedOut: NWListener?) {
        guard let startup, let timedOut, timedOut === listener else { return }
        self.startup = nil
        listener?.cancel()
        listener = nil
        startup.resume(throwing: HomeError("The iMCP Helper listener did not start within 10 seconds."))
    }

    private func accept(_ connection: NWConnection, from acceptor: NWListener?) async {
        // A listener that a restart replaced still uses the old credential.
        guard let acceptor, acceptor === listener else {
            connection.cancel()
            return
        }
        let id = UUID()
        let credential = self.credential
        // Register before the first suspension, so a restart in between cancels this connection.
        sessions[id] = connection
        let server: MCP.Server
        switch credential {
        case .code(let code):
            // A pairing connection can only send the key; it can't list or call tools.
            server = MCP.Server(
                name: "iMCP Helper",
                version: Bundle.main.shortVersionString ?? "1.0",
                configuration: .strict
            )
            await server.withMethodHandler(HomeHelperPairing.Pair.self) { [weak self] parameters in
                guard let self else { throw MCPError.internalError("iMCP Helper stopped.") }
                try await self.receivePairing(parameters.key, session: id, code: code)
                return Empty()
            }
        case .key:
            server = MCP.Server(
                name: "iMCP Helper",
                version: Bundle.main.shortVersionString ?? "1.0",
                capabilities: .init(tools: .init(listChanged: false)),
                // Strict mode refuses every request but ping before initialize.
                configuration: .strict
            )
            await serveTools(on: server)
        }
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )
        await willStartSession()
        // A restart while the handlers were registered replaced this connection's listener.
        guard acceptor === listener, sessions[id] != nil else {
            sessions.removeValue(forKey: id)
            connection.cancel()
            return
        }
        // End a connection that doesn't complete the TLS handshake and initialize promptly.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        do {
            try await server.start(transport: transport) { _, _ in
                // Network.framework also accepts its default PSK suites, which lack forward secrecy.
                // Answering ping before this check is harmless: a peer needs the key to finish the handshake,
                // and the TLS 1.2 Finished message covers the offered suites, so this isn't a downgrade path.
                guard HomeHelperPairing.usesCipherSuite(connection) else {
                    connection.cancel()
                    throw MCPError.invalidRequest("iMCP Helper requires an ECDHE-PSK cipher suite.")
                }
                deadline.cancel()
            }
            await server.waitUntilCompleted()
        } catch {
            if case .code(let code) = credential, Self.failedHandshake(connection.state) {
                await countFailedPairing(code: code)
            }
            log.error("Home connection failed: \(error.localizedDescription)")
        }
        deadline.cancel()
        await server.stop()
        sessions.removeValue(forKey: id)
        connection.cancel()
        await reportPairing()
    }

    /// Reports a pairing once, after the helper stored the key and its connection ended,
    /// so iMCP receives the response first.
    private func reportPairing() async {
        guard var pairing, pairing.stored, !pairing.reported, sessions[pairing.session] == nil else { return }
        pairing.reported = true
        self.pairing = pairing
        await onEvent(.paired(pairing.key, code: pairing.code))
    }

    private func serveTools(on server: MCP.Server) async {
        let tools = HomeKitService(backend: backend).tools
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
                    throw HomeError("Unknown Home tool: \(params.name)")
                }
                try HomeInput.validate(params.arguments ?? [:], schema: tool.inputSchema)
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
    }

    /// Accepts the key from the first pairing connection that sends one,
    /// and stores it before the response acknowledges it.
    func receivePairing(_ key: Data, session: UUID, code: String) async throws {
        // swift-sdk runs handlers in their own tasks, so this can run after the session ended.
        guard sessions[session] != nil, case .code(let current) = credential, current == code, pairing == nil else {
            throw Self.refusal("This pairing code was already used.")
        }
        guard key.count == 32 else { throw Self.refusal("iMCP Helper can't use this pairing.") }
        let claimed = Pairing(session: session, key: SymmetricKey(data: key), code: code)
        pairing = claimed
        do {
            try await storeKey(claimed.key, code)
        } catch {
            if pairing?.id == claimed.id { pairing = nil }
            throw Self.refusal("iMCP Helper couldn't save the pairing: \(error.localizedDescription)")
        }
        // A restart while the key was stored replaced this pairing.
        guard pairing?.id == claimed.id else { throw Self.refusal("This pairing code was replaced.") }
        pairing?.stored = true
        // The code works once: stop accepting it, and end the other pairing connections.
        stopListening()
        for (other, connection) in sessions where other != session { connection.cancel() }
        // The session may have ended while the key was stored.
        await reportPairing()
        // iMCP closes the connection after the response; end it if iMCP doesn't.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.endSession(session)
        }
    }

    /// An error that tells iMCP the helper didn't keep the key.
    private static func refusal(_ message: String) -> MCPError {
        .serverError(code: HomeHelperPairing.refusalCode, message: message)
    }

    private func endSession(_ id: UUID) {
        sessions[id]?.cancel()
    }

    private func countFailedPairing(code: String) async {
        guard case .code(let current) = credential, current == code, pairing == nil else { return }
        failedPairings += 1
        guard failedPairings == HomeHelperPairing.failedPairingLimit else { return }
        // Stop accepting guesses at once; the window shows a new code.
        stopListening()
        await onEvent(.tooManyFailedPairings(code: code))
    }

    /// Whether a connection failed its TLS handshake, which means the keys differ.
    private static func failedHandshake(_ state: NWConnection.State) -> Bool {
        switch state {
        case .waiting(.tls), .failed(.tls): true
        default: false
        }
    }
}

struct HomeKitService: Service {
    let backend: any HomeBackend
    var tools: [Tool] { return HomeTools.tools(backend: backend) }
}
