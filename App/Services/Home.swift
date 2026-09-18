import AppKit
import Darwin
import MCP
import Network
import OSLog

/// Serves the Home tools by proxying to the Catalyst helper that holds HomeKit access.
///
/// HomeKit is not available to native macOS apps,
/// so the helper runs as a separate app in `Contents/Helpers`
/// and implements the same tool definitions from `HomeTools`.
/// This service launches the helper, connects to it over the loopback interface,
/// and forwards each call as an MCP `tools/call` request.
actor HomeService: Service, HomeBackend {
    static let shared = HomeService()

    private let log = Logger.service("home")
    private let helperURL: URL?
    private var client: MCP.Client?
    private var connection: NWConnection?
    private var connecting: Task<Void, Error>?
    private var authorized = false
    private var launchedHelper: LaunchedHelper?

    private struct LaunchedHelper: Sendable {
        let pid: pid_t
        let endpoint: NWEndpoint
    }

    init(helperURL: URL? = nil) { self.helperURL = helperURL }

    // MARK: - Service

    nonisolated var tools: [Tool] { return HomeTools.tools(backend: self) }

    var isActivated: Bool { authorized && connection?.state == .ready }

    func activate() async throws {
        if isActivated { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    // MARK: - HomeBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        try await activate()
        guard let active = client else { throw HomeError("iMCP Helper is not connected.") }
        do { return try await forward(active, tool, input) } catch let error as HomeError { throw error } catch {
            if client === active {
                authorized = false
                client = nil
                connection?.cancel()
                connection = nil
                await active.disconnect()
            }
            try await activate()
            // A lost response does not prove that a write failed. Never duplicate a write.
            guard tools.first(where: { $0.name == tool })?.annotations.readOnlyHint == true
            else {
                throw HomeError(
                    "The iMCP Helper connection was lost. The write may have completed. Inspect the home before retrying."
                )
            }
            guard let client else { throw HomeError("iMCP Helper could not reconnect.") }
            return try await forward(client, tool, input)
        }
    }

    // MARK: - Connection

    private func forward(_ client: MCP.Client, _ tool: String, _ input: [String: Value]) async throws -> Value {
        let connection = self.connection
        let monitor = Task {
            guard let connection else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                switch connection.state {
                case .failed, .cancelled, .waiting:
                    await client.disconnect()
                    return
                default: break
                }
            }
        }
        defer { monitor.cancel() }
        let result = try await client.callTool(name: tool, arguments: input)
        let texts = result.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }
        if result.isError == true { throw HomeError(texts.joined(separator: "\n")) }
        guard let text = texts.first, let data = text.data(using: .utf8) else {
            throw HomeError("iMCP Helper returned no JSON text.")
        }
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw HomeError("iMCP Helper returned invalid JSON: \(error.localizedDescription)")
        }
    }

    private func connect() async throws {
        authorized = false
        let old = client
        client = nil
        connection?.cancel()
        connection = nil
        await old?.disconnect()
        launchedHelper = try await launchHelper(previous: launchedHelper, overrideURL: helperURL)
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let endpoint: NWEndpoint
        if let launchedHelper {
            endpoint = launchedHelper.endpoint
        } else {
            let browser = NWBrowser(for: .bonjour(type: "_imcp-helper._tcp", domain: "local."), using: .tcp)
            do {
                endpoint = try await BonjourDiscovery.discoverEndpoint(
                    using: browser,
                    timeout: .seconds(15),
                    preferring: { String(describing: $0.endpoint).contains("iMCP Helper") }
                )
            } catch {
                throw HomeError(
                    "iMCP Helper was not found. Quit any manually started iMCP Helper and enable Home again. \(error.localizedDescription)"
                )
            }
        }
        let deadline = Date().addingTimeInterval(15)
        repeat {
            do {
                try await connect(to: endpoint, parameters: parameters)
                return
            } catch let error as HomeError { throw error } catch {
                guard launchedHelper != nil, Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while true
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters) async throws {
        let connection = NWConnection(to: endpoint, using: parameters)
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )
        let client = MCP.Client(name: "iMCP", version: Bundle.main.shortVersionString ?? "unknown")
        let timeout = Task {
            // NetworkTransport waits indefinitely in NWConnection.waiting.
            // Retry refused connections while the helper starts.
            for _ in 0 ..< 80 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                if case .waiting = connection.state { break }
            }
            connection.cancel()
            await client.disconnect()
        }
        defer { timeout.cancel() }
        do {
            let result = try await client.connect(transport: transport)
            guard result.serverInfo.name == "iMCP Helper" else {
                throw HomeError("The selected endpoint is not iMCP Helper.")
            }
            _ = try await forward(client, "homes_list", [:])
            self.client = client
            self.connection = connection
            authorized = true
            log.info("Connected to iMCP Helper")
        } catch {
            connection.cancel()
            await client.disconnect()
            throw error
        }
    }

    // MARK: - Helper Launch

    @MainActor
    private func launchHelper(previous: LaunchedHelper?, overrideURL: URL?) async throws -> LaunchedHelper? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "co.dododo.iMCP.Helper" && !$0.isTerminated
        }) {
            return previous?.pid == running.processIdentifier ? previous : nil
        }
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iMCP Helper.app")
        let url =
            overrideURL
            ?? (FileManager.default.fileExists(atPath: embedded.path)
                ? embedded : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "co.dododo.iMCP.Helper"))
        guard let url else { return nil }
        let port = try availableLoopbackPort()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--parent-pid", String(getpid()), "--port", String(port)]
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return LaunchedHelper(
            pid: application.processIdentifier,
            endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        )
    }

    /// Selects an ephemeral loopback port for the child process.
    /// The helper reports a bind error if another process takes it before launch.
    private nonisolated func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HomeError("Cannot allocate a socket for iMCP Helper.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw HomeError("Cannot bind a socket for iMCP Helper.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard nameResult == 0 else { throw HomeError("Cannot select a port for iMCP Helper.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
