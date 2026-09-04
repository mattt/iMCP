import Logging
import MCP
import Network
import ServiceLifecycle
import SystemPackage

import struct Foundation.Data
import class Foundation.RunLoop

var log = Logger(label: "me.mattt.iMCP.server") { StreamLogHandler.standardError(label: $0) }
#if DEBUG
    log.logLevel = .debug
#else
    log.logLevel = .warning
#endif

// Network setup
let serviceType = "_mcp._tcp"
let parameters = NWParameters.tcp
parameters.acceptLocalOnly = true
parameters.includePeerToPeer = false

if let tcpOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
    tcpOptions.version = .v4
}

/// An actor that provides a configurable proxy between standard I/O and network connections
actor StdioProxy {
    // Connection configuration
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let stdinBufferSize: Int
    private let networkBufferSize: Int

    // Connection state
    private var connection: NWConnection?
    private var isRunning = false

    // Message buffering for proper JSON-RPC message boundaries
    private var networkToStdoutBuffer = Data()

    /// Creates a new StdioProxy with the specified network configuration
    /// - Parameters:
    ///   - endpoint: The network endpoint to connect to
    ///   - parameters: Network connection parameters
    ///   - stdinBufferSize: Buffer size for reading from stdin (default: 4096)
    ///   - networkBufferSize: Buffer size for reading from network (default: 4096)
    init(
        endpoint: NWEndpoint,
        parameters: NWParameters = .tcp,
        stdinBufferSize: Int = 10 * 1024 * 1024,
        networkBufferSize: Int = 10 * 1024 * 1024
    ) {
        self.endpoint = endpoint
        self.parameters = parameters
        self.stdinBufferSize = stdinBufferSize
        self.networkBufferSize = networkBufferSize
    }

    /// Starts the proxy
    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Create the connection
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        // Start the connection
        connection.start(queue: .main)

        // Set up state monitoring for the entire lifetime of the connection
        connection.stateUpdateHandler = { state in
            Task { [weak self] in
                await self?.handleConnectionState(state, continuation: nil, connectionState: nil)
            }
        }

        // Wait for the connection to become ready
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Swift.Error>) in
            let connectionState = ConnectionState()
            connection.stateUpdateHandler = { state in
                Task { [weak self] in
                    await self?.handleConnectionState(
                        state,
                        continuation: continuation,
                        connectionState: connectionState
                    )
                }
            }
        }

        // Create a structured concurrency task group for handling I/O
        var sessionError: (any Swift.Error)?
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Add task for handling stdin to network
                group.addTask { [stdinBufferSize] in
                    do {
                        try await self.handleStdinToNetwork(bufferSize: stdinBufferSize)
                    } catch {
                        await log.error("Stdin handler failed: \(error)")
                        throw error
                    }
                }

                // Add task for handling network to stdout
                group.addTask { [networkBufferSize] in
                    do {
                        try await self.handleNetworkToStdout(bufferSize: networkBufferSize)
                    } catch {
                        await log.error("Network handler failed: \(error)")
                        throw error
                    }
                }

                // Wait for any task to complete (or fail).
                // On throw, skip a bare `cancelAll()`: the sibling is often
                // parked in `NWConnection.receive`, which is not
                // cancellation-aware. Cancel the connection first so that
                // receive completes and the group can finish unwinding.
                let firstError: (any Swift.Error)?
                do {
                    try await group.next()
                    firstError = nil
                } catch {
                    firstError = error
                }
                await log.debug("A task completed, cancelling remaining tasks")
                await self.stop()
                group.cancelAll()
                if let firstError {
                    throw firstError
                }
            }
        } catch {
            sessionError = error
        }

        await self.stop()
        if let sessionError {
            throw sessionError
        }
    }

    /// Stops the proxy and cleans up resources
    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
    }

    /// Handles connection state changes
    private func handleConnectionState(
        _ state: NWConnection.State,
        continuation: CheckedContinuation<Void, Swift.Error>?,
        connectionState: ConnectionState?
    ) async {
        switch state {
        case .ready:
            await log.debug("Connection established to \(endpoint)")
            if await shouldResume(connectionState: connectionState) {
                continuation?.resume()
            }
        case .failed(let error):
            await log.debug("Connection failed: \(error)")
            if let continuation = continuation,
                await shouldResume(connectionState: connectionState)
            {
                continuation.resume(throwing: error)
            }
            await stop()
        case .cancelled:
            await log.debug("Connection cancelled")
            if let continuation = continuation,
                await shouldResume(connectionState: connectionState)
            {
                continuation.resume(throwing: CancellationError())
            }
            await stop()
        case .waiting(let error):
            await log.debug("Connection waiting: \(error)")
        case .preparing:
            await log.debug("Connection preparing...")
        case .setup:
            await log.debug("Connection setup...")
        @unknown default:
            await log.debug("Unknown connection state")
        }
    }

    private func shouldResume(connectionState: ConnectionState?) async -> Bool {
        if let connectionState = connectionState {
            return await connectionState.checkAndSetResumed()
        }
        return true
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno.badFileDescriptor)
        }
    }

    /// Handles forwarding data from stdin to the network
    private func handleStdinToNetwork(bufferSize: Int) async throws {
        let stdin = FileDescriptor.standardInput
        try setNonBlocking(fileDescriptor: stdin)

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping stdin handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
                // Read data from stdin using SystemPackage approach
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdin.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    // The MCP client closed stdin. Exit rather than return:
                    // a clean return made MCPService reconnect in a tight loop
                    // while stdin stayed at EOF.
                    await log.debug("EOF reached on stdin, stopping stdin handler")
                    throw StdioProxyError.connectionClosed
                }

                if bytesRead > 0 {
                    // Append the read bytes to pending data
                    pendingData.append(contentsOf: buffer[0 ..< bytesRead])

                    // Check if the data is only whitespace
                    let isOnlyWhitespace = pendingData.allSatisfy {
                        let char = Character(UnicodeScalar($0))
                        return char.isWhitespace || char.isNewline
                    }

                    // Only send if we have non-whitespace content
                    if !isOnlyWhitespace && !pendingData.isEmpty {
                        // Send data to the network connection
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<Void, Swift.Error>) in
                            connection.send(
                                content: pendingData,
                                completion: .contentProcessed { error in
                                    if let error = error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume()
                                    }
                                }
                            )
                        }

                        await log.debug("Sent \(pendingData.count) bytes to network")
                    } else if isOnlyWhitespace && !pendingData.isEmpty {
                        await log.trace(
                            "Skipping send of \(pendingData.count) whitespace-only bytes"
                        )
                    }

                    // Clear pending data after processing
                    pendingData.removeAll(keepingCapacity: true)
                }
            } catch let error as StdioProxyError {
                throw error
            } catch {
                if let posixError = error as? Errno, posixError == .wouldBlock {
                    try await Task.sleep(for: .milliseconds(10))  // Keep the sleep to yield CPU
                    continue
                }

                await log.error("Error in stdin handler: \(error)")
                throw error
            }
        }
    }

    /// Handles forwarding data from the network to stdout
    private func handleNetworkToStdout(bufferSize: Int) async throws {
        let stdout = FileDescriptor.standardOutput
        var consecutiveEmptyReads = 0
        let maxConsecutiveEmptyReads = 100  // After this many consecutive empty reads, we'll check connection state

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping network handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping network handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
                // Check connection state periodically if we're getting consecutive empty reads
                if consecutiveEmptyReads > 0
                    && consecutiveEmptyReads % maxConsecutiveEmptyReads == 0
                {
                    // If we've had too many empty reads, consider it a timeout
                    if consecutiveEmptyReads > maxConsecutiveEmptyReads * 10 {
                        await log.warning(
                            "Network read timed out after \(consecutiveEmptyReads) consecutive empty reads"
                        )
                        throw StdioProxyError.networkTimeout
                    }
                }

                // Receive data from the network connection
                let data = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Swift.Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: bufferSize) {
                        data,
                        _,
                        isComplete,
                        error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }

                        if let data = data {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            log.debug("Network connection complete")
                            continuation.resume(throwing: StdioProxyError.connectionClosed)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }

                var processedData = data

                // Check for and filter out heartbeat messages using MCP.NetworkTransport.Heartbeat
                // Assuming MCP module and NetworkTransport.Heartbeat are available
                if NetworkTransport.Heartbeat.isHeartbeat(processedData) {
                    await log.debug(
                        "Heartbeat signature detected in received network data using MCP definition."
                    )

                    // Try to parse a full heartbeat. MCP.NetworkTransport.Heartbeat.from(data:) checks for minimum length internally.
                    if let heartbeat = NetworkTransport.Heartbeat.from(data: processedData) {
                        let heartbeatLength = heartbeat.rawValue.count  // This should typically be 12
                        await log.debug(
                            "Full MCP heartbeat message (\(heartbeatLength) bytes) received from network, skipping output."
                        )
                        // Remove the full heartbeat from the data
                        processedData = processedData.dropFirst(heartbeatLength)
                    } else {
                        // MCP.NetworkTransport.Heartbeat.isHeartbeat was true, but .from(data:) failed.
                        // This means we have the magic bytes but not the full message (e.g., data length < 12 but >= 4).
                        let expectedHeartbeatLength = MCP.NetworkTransport.Heartbeat().rawValue
                            .count  // Get expected length (12)
                        await log.debug(
                            "Partial MCP heartbeat message (<\(expectedHeartbeatLength) bytes) received, discarding this chunk to prevent garbled output."
                        )
                        processedData = Data()  // Discard the chunk
                    }
                }

                if processedData.isEmpty {
                    // No data available (or entire chunk was a heartbeat), yield to other tasks
                    // If original data was not empty, but processedData is, it means it was a heartbeat.
                    if !data.isEmpty {  // Original data was not empty, so this was a heartbeat
                        consecutiveEmptyReads = 0  // Reset counter as we did receive something (a heartbeat)
                    } else {
                        consecutiveEmptyReads += 1
                    }
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } else {
                    // Reset counter when we get actual data (not just a heartbeat)
                    consecutiveEmptyReads = 0
                    await log.debug(
                        "Received \(processedData.count) bytes of application data from network"
                    )
                }

                // Add data to buffer for message assembly
                networkToStdoutBuffer.append(processedData)

                // Process complete messages (delimited by newlines)
                while let newlineIndex = networkToStdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = networkToStdoutBuffer[..<newlineIndex]
                    var messageWithNewline = Data(messageData)
                    messageWithNewline.append(UInt8(ascii: "\n"))

                    // Remove processed message from buffer
                    networkToStdoutBuffer = networkToStdoutBuffer[(newlineIndex + 1)...]

                    // Write complete message to stdout
                    var remainingDataToWrite = messageWithNewline
                    while !remainingDataToWrite.isEmpty {
                        let bytesWritten: Int = try remainingDataToWrite.withUnsafeBytes { buffer in
                            try stdout.write(UnsafeRawBufferPointer(buffer))
                        }

                        if bytesWritten < remainingDataToWrite.count {
                            await log.debug(
                                "Partial write: \(bytesWritten) of \(remainingDataToWrite.count) bytes"
                            )
                            // Remove the bytes that were written
                            remainingDataToWrite = remainingDataToWrite.dropFirst(bytesWritten)
                        } else {
                            // All bytes were written
                            remainingDataToWrite.removeAll()
                        }

                        // If we still have data to write, give a small delay to allow the system to process
                        if !remainingDataToWrite.isEmpty {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    }
                }
            } catch let error as NWError where error.errorCode == 96 {
                // Handle "No message available on STREAM" error
                await log.debug("Network read yielded no data, waiting...")
                consecutiveEmptyReads += 1
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Check if the connection was cancelled or closed
                if let nwError = error as? NWError,
                    nwError.errorCode == 57  // Socket is not connected
                        || nwError.errorCode == 54  // Connection reset by peer
                {
                    await log.debug("Connection closed by peer: \(error)")
                    throw StdioProxyError.connectionClosed
                }

                if error is StdioProxyError {
                    throw error
                }

                await log.error("Error in network handler: \(error)")
                throw error
            }
        }
    }
}

// Create MCPService class to manage lifecycle
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

                // Create the proxy
                let proxy = StdioProxy(
                    endpoint: endpoint,
                    parameters: parameters,
                    stdinBufferSize: 10 * 1024 * 1024,  // 10MB for large responses
                    networkBufferSize: 10 * 1024 * 1024  // 10MB for large responses
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
                // Handle discovery and other errors with retry
                await log.error("Connection error: \(error)")
                await log.info("Will retry connection in 5 seconds...")
                try await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// `.gracefullyShutdownGroup` is load-bearing: `MCPService.run()` returns
// when the Bonjour connection to the menubar app drops. With the library
// default of `.cancelGroup`, that return raises `ServiceGroupError` at the
// top level → Swift runtime fatal error. See ServiceGroupConfigurationTests.
let lifecycle = ServiceGroup(
    configuration: .init(
        services: [
            .init(
                service: MCPService(),
                successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup
            )
        ],
        gracefulShutdownSignals: [.sigint, .sigterm],
        logger: log
    )
)

try await lifecycle.run()
