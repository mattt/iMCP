import Logging
import MCP
import Network
import ServiceLifecycle

private let serviceType = "_mcp._tcp"

private let parameters: NWParameters = {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    parameters.includePeerToPeer = false

    if let tcpOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
        tcpOptions.version = .v4
    }

    return parameters
}()

/// Discovers the menubar app over Bonjour and proxies stdio to it.
actor MCPService: Service {
    private var currentProxy: StdioProxy?

    func run() async throws {
        while !Task.isShuttingDownGracefully {
            do {
                await log.info("Starting Bonjour service discovery...")

                let browser = NWBrowser(
                    for: .bonjour(type: serviceType, domain: nil),
                    using: parameters
                )

                // Prefer a service advertised as iMCP; fall back to any MCP service.
                // The helper cancels the browser on every exit path,
                // so a timed-out attempt doesn't leak a DNS-SD connection (#192).
                let endpoint: NWEndpoint
                do {
                    endpoint = try await BonjourDiscovery.discoverEndpoint(
                        using: browser,
                        timeout: .seconds(30),
                        preferring: { String(describing: $0.endpoint).contains("iMCP") }
                    )
                } catch BonjourDiscovery.Error.timeout {
                    await log.error("Bonjour service discovery timed out after 30 seconds")
                    throw MCPError.internalError("Service discovery timeout")
                }
                await log.info("Selected endpoint: \(endpoint)")

                await log.info("Creating connection to endpoint...")

                let proxy = StdioProxy(
                    endpoint: endpoint,
                    parameters: parameters,
                    stdinBufferSize: 10 * 1024 * 1024,
                    networkBufferSize: 10 * 1024 * 1024
                )
                self.currentProxy = proxy

                let sessionError: (any Swift.Error)?
                do {
                    try await proxy.start()
                    sessionError = nil
                } catch {
                    sessionError = error
                }

                switch MCPServiceLoop.decision(error: sessionError) {
                case .terminate:
                    await log.critical("Connection closed, terminating...")
                    return
                case .reconnect(let seconds):
                    if let sessionError {
                        await log.error("Connection error: \(sessionError)")
                    }
                    await log.info("Will retry connection in \(Int(seconds)) seconds...")
                    try await Task.sleep(for: .seconds(seconds))
                }
            } catch {
                await log.error("Connection error: \(error)")
                await log.info("Will retry connection in 5 seconds...")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }
}
