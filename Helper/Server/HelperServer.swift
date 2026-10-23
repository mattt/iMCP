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

    private let backend: any HomeBackend
    private let onEvent: @Sendable (Event) async -> Void
    private var credential: Credential
    private var listener: NWListener?
    private var sessions: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var failedPairings = 0
    /// Set when a pairing connection sends a key, so the code works only once.
    private var pairing: (session: UUID, key: SymmetricKey, code: String)?
    private let log = Logger.service("helper.server")

    init(
        backend: any HomeBackend,
        credential: Credential,
        onEvent: @escaping @Sendable (Event) async -> Void = { _ in }
    ) {
        self.backend = backend
        self.credential = credential
        self.onEvent = onEvent
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
        stopListening()
        for connection in sessions.values { connection.cancel() }
        self.credential = credential
        failedPairings = 0
        pairing = nil
        return try await start()
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
        sessions[id] = connection
        // End a connection that doesn't complete the TLS handshake and initialize promptly.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        do {
            try await server.start(transport: transport) { _, _ in
                // Network.framework also accepts its default PSK suites, which lack forward secrecy.
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
        // Report a pairing once its connection ends, so iMCP receives the response first.
        if let pairing, pairing.session == id {
            await onEvent(.paired(pairing.key, code: pairing.code))
        }
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

    /// Accepts the key from the first pairing connection that sends one.
    private func receivePairing(_ key: Data, session: UUID, code: String) throws {
        guard case .code(let current) = credential, current == code, pairing == nil else {
            throw MCPError.invalidRequest("This pairing code was already used.")
        }
        guard key.count == 32 else { throw MCPError.invalidParams("The pairing key must have 256 bits.") }
        pairing = (session, SymmetricKey(data: key), code)
        // The code works once: stop accepting it, and end the other pairing connections.
        stopListening()
        for (other, connection) in sessions where other != session { connection.cancel() }
        // iMCP closes the connection after the response; end it if iMCP doesn't.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.endSession(session)
        }
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
