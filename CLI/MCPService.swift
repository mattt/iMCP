import Darwin
import Foundation
import Logging
import ServiceLifecycle

/// Connects to the menubar app over its Unix domain socket and proxies stdio to it.
actor MCPService: Service {
    private var currentProxy: StdioProxy?

    func run() async throws {
        var hasReportedUnavailable = false
        while !Task.isShuttingDownGracefully {
            do {
                // Check the app's code signature before writing anything to the socket.
                let (socket, path) = try LocalSocket.connect(
                    toFirstOf: LocalSocket.clientPaths(),
                    requiring: CodeRequirement.server
                )
                hasReportedUnavailable = false
                await log.info("Connected to iMCP at \(path)")

                let proxy = StdioProxy(socket: socket, stdinBufferSize: 10 * 1024 * 1024)
                self.currentProxy = proxy

                let sessionError: (any Swift.Error)?
                do {
                    // Send the client's credential only to an app that passed the check.
                    let hello = LocalSocketHello.fromEnvironment(ProcessInfo.processInfo.environment)
                    try await proxy.start(hello: hello.encoded())
                    sessionError = nil
                } catch {
                    sessionError = error
                }

                let hasReadClientInput = await proxy.hasReadInput
                switch MCPServiceLoop.decision(error: sessionError, hasReadClientInput: hasReadClientInput) {
                case .terminate:
                    if let sessionError {
                        // A new connection wouldn't have this session's approval.
                        await log.critical(
                            "Connection error: \(sessionError). Exiting so that the MCP client can start a new session."
                        )
                    } else {
                        await log.critical("Connection closed, terminating...")
                    }
                    return
                case .reconnect(let seconds):
                    if let sessionError {
                        await log.error("Connection error: \(sessionError)")
                    }
                    await log.info("Will retry connection in \(Int(seconds)) seconds...")
                    try await Task.sleep(for: .seconds(seconds))
                }
            } catch let error as CodeRequirement.UntrustedPeer {
                await log.critical("\(error)")
                try await Task.sleep(for: .seconds(5))
            } catch let error as LocalSocket.Error {
                // Report once while the app isn't running, then keep trying quietly.
                if !hasReportedUnavailable {
                    hasReportedUnavailable = true
                    await log.error(
                        "Couldn't connect to iMCP: \(error). Check that iMCP is open and that its server is turned on."
                    )
                }
                try await Task.sleep(for: .seconds(2))
            } catch {
                await log.error("Connection error: \(error)")
                await log.info("Will retry connection in 5 seconds...")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }
}
