import Foundation
import MCP
import Network
import OSLog
import Ontology

/// Serves the Home tools over TLS with the pairing code's pre-shared key.
actor HelperServer {
    private let backend: any HomeBackend
    private var code: String
    private var listener: NWListener?
    private var sessions: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private let log = Logger.service("helper.server")

    init(backend: any HomeBackend, code: String) {
        self.backend = backend
        self.code = code
    }

    /// Listens on an ephemeral loopback port and returns the port.
    /// The helper's window doesn't start, retry, or restart while another of these runs,
    /// so calls don't overlap.
    func start() async throws -> NWEndpoint.Port {
        if let port = listener?.port { return port }
        return try await listen()
    }

    private func listen() async throws -> NWEndpoint.Port {
        let parameters = try HomeHelperPairing.parameters(code: code)
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
    /// and listens again with a new pairing code.
    /// Returns the new port.
    ///
    /// Tool calls that a session already accepted can still finish:
    /// swift-sdk's `Server.stop()` doesn't cancel request handlers,
    /// and HomeKit mutations with several steps don't check the session between steps.
    func restart(code: String) async throws -> NWEndpoint.Port {
        stopListening()
        for connection in sessions.values { connection.cancel() }
        self.code = code
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
        // A listener that a restart replaced still uses the old pairing code.
        guard let acceptor, acceptor === listener else {
            connection.cancel()
            return
        }
        let id = UUID()
        let server = MCP.Server(
            name: "iMCP Helper",
            version: Bundle.main.shortVersionString ?? "1.0",
            capabilities: .init(tools: .init(listChanged: false)),
            // Strict mode refuses every request but ping before initialize.
            configuration: .strict
        )
        let tools = HomeKitService(backend: backend).tools
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )
        sessions[id] = connection
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
        // End a connection that doesn't complete the TLS handshake and initialize promptly.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        do {
            try await server.start(transport: transport) { _, _ in deadline.cancel() }
            await server.waitUntilCompleted()
        } catch { log.error("Home connection failed: \(error.localizedDescription)") }
        deadline.cancel()
        await server.stop()
        sessions.removeValue(forKey: id)
        connection.cancel()
    }
}

struct HomeKitService: Service {
    let backend: any HomeBackend
    var tools: [Tool] { return HomeTools.tools(backend: backend) }
}
