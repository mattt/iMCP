import Foundation
import MCP
import Network
import OSLog
import Ontology

actor HelperServer {
    private let backend: any HomeBackend
    private let port: NWEndpoint.Port?
    private var listener: NWListener?
    private var advertisement: HomeAdvertisement?
    private var sessions: [UUID: MCP.Server] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private let log = Logger.service("home.server")

    init(backend: any HomeBackend, port: NWEndpoint.Port? = nil) {
        self.backend = backend
        self.port = port
    }

    func start() async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port ?? .any)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.start(queue: .main)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.startupTimedOut()
            }
        }
        // Parent-launched helpers use the private port passed by iMCP.
        // Manual launches retain Bonjour discovery for development clients.
        if port != nil { return }
        guard let port = listener.port else { throw HomeError("The Home helper has no TCP port.") }
        let advertisement = await HomeAdvertisement()
        self.advertisement = advertisement
        do { try await advertisement.start(port: port.rawValue) } catch {
            listener.cancel()
            self.listener = nil
            await advertisement.stop()
            self.advertisement = nil
            throw error
        }
    }

    private func stateChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            startup?.resume()
            startup = nil
        case .failed(let error):
            startup?.resume(throwing: error)
            startup = nil
            listener?.cancel()
            listener = nil
            await advertisement?.stop()
            advertisement = nil
            log.error("Home listener failed: \(error.localizedDescription)")
        default: break
        }
    }
    private func startupTimedOut() {
        guard let startup else { return }
        self.startup = nil
        listener?.cancel()
        listener = nil
        startup.resume(throwing: HomeError("The Home helper listener did not start within 10 seconds."))
    }

    private func accept(_ connection: NWConnection) async {
        let id = UUID()
        let server = MCP.Server(
            name: "iMCP Home",
            version: Bundle.main.shortVersionString ?? "1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let tools = HomeKitService(backend: backend).tools
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )
        sessions[id] = server
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
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch { log.error("Home connection failed: \(error.localizedDescription)") }
        await server.stop()
        sessions.removeValue(forKey: id)
        connection.cancel()
    }
}

struct HomeKitService: Service {
    let backend: any HomeBackend
    var tools: [Tool] { return HomeTools.tools(backend: backend) }
}
