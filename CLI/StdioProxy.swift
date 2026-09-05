import Logging
import MCP
import Network
import SystemPackage

import struct Foundation.Data

/// A configurable proxy between standard I/O and a network connection.
actor StdioProxy {
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let stdinBufferSize: Int
    private let networkBufferSize: Int

    private var connection: NWConnection?
    private var isRunning = false

    private var networkToStdoutBuffer = Data()

    /// Creates a proxy that forwards stdin to `endpoint` and network data to stdout.
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to connect to.
    ///   - parameters: Network connection parameters.
    ///   - stdinBufferSize: Buffer size for reading from stdin.
    ///   - networkBufferSize: Buffer size for reading from the network.
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

    /// Starts the proxy.
    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.start(queue: .main)

        connection.stateUpdateHandler = { state in
            Task { [weak self] in
                await self?.handleConnectionState(state, continuation: nil, connectionState: nil)
            }
        }

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

        var sessionError: (any Swift.Error)?
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [stdinBufferSize] in
                    do {
                        try await self.handleStdinToNetwork(bufferSize: stdinBufferSize)
                    } catch {
                        await log.error("Stdin handler failed: \(error)")
                        throw error
                    }
                }

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

    /// Stops the proxy and releases the network connection.
    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
    }

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

    private func handleStdinToNetwork(bufferSize: Int) async throws {
        let stdin = FileDescriptor.standardInput
        try setNonBlocking(fileDescriptor: stdin)

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while true {
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping stdin handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
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
                    pendingData.append(contentsOf: buffer[0 ..< bytesRead])

                    let isOnlyWhitespace = pendingData.allSatisfy {
                        let char = Character(UnicodeScalar($0))
                        return char.isWhitespace || char.isNewline
                    }

                    if !isOnlyWhitespace && !pendingData.isEmpty {
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

                    pendingData.removeAll(keepingCapacity: true)
                }
            } catch let error as StdioProxyError {
                throw error
            } catch {
                if let posixError = error as? Errno, posixError == .wouldBlock {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }

                await log.error("Error in stdin handler: \(error)")
                throw error
            }
        }
    }

    private func handleNetworkToStdout(bufferSize: Int) async throws {
        let stdout = FileDescriptor.standardOutput
        var consecutiveEmptyReads = 0
        let maxConsecutiveEmptyReads = 100

        while true {
            guard isRunning, let connection = self.connection else {
                await log.debug("Connection no longer active, stopping network handler")
                throw StdioProxyError.connectionClosed
            }

            if connection.state != .ready && connection.state != .preparing {
                await log.debug(
                    "Connection state changed to \(connection.state), stopping network handler"
                )
                throw StdioProxyError.connectionClosed
            }

            do {
                if consecutiveEmptyReads > 0
                    && consecutiveEmptyReads % maxConsecutiveEmptyReads == 0
                {
                    if consecutiveEmptyReads > maxConsecutiveEmptyReads * 10 {
                        await log.warning(
                            "Network read timed out after \(consecutiveEmptyReads) consecutive empty reads"
                        )
                        throw StdioProxyError.networkTimeout
                    }
                }

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

                if NetworkTransport.Heartbeat.isHeartbeat(processedData) {
                    await log.debug(
                        "Heartbeat signature detected in received network data using MCP definition."
                    )

                    if let heartbeat = NetworkTransport.Heartbeat.from(data: processedData) {
                        let heartbeatLength = heartbeat.rawValue.count
                        await log.debug(
                            "Full MCP heartbeat message (\(heartbeatLength) bytes) received from network, skipping output."
                        )
                        processedData = processedData.dropFirst(heartbeatLength)
                    } else {
                        let expectedHeartbeatLength = MCP.NetworkTransport.Heartbeat().rawValue
                            .count
                        await log.debug(
                            "Partial MCP heartbeat message (<\(expectedHeartbeatLength) bytes) received, discarding this chunk to prevent garbled output."
                        )
                        processedData = Data()
                    }
                }

                if processedData.isEmpty {
                    if !data.isEmpty {
                        consecutiveEmptyReads = 0
                    } else {
                        consecutiveEmptyReads += 1
                    }
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } else {
                    consecutiveEmptyReads = 0
                    await log.debug(
                        "Received \(processedData.count) bytes of application data from network"
                    )
                }

                networkToStdoutBuffer.append(processedData)

                while let newlineIndex = networkToStdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = networkToStdoutBuffer[..<newlineIndex]
                    var messageWithNewline = Data(messageData)
                    messageWithNewline.append(UInt8(ascii: "\n"))

                    networkToStdoutBuffer = networkToStdoutBuffer[(newlineIndex + 1)...]

                    var remainingDataToWrite = messageWithNewline
                    while !remainingDataToWrite.isEmpty {
                        let bytesWritten: Int = try remainingDataToWrite.withUnsafeBytes { buffer in
                            try stdout.write(UnsafeRawBufferPointer(buffer))
                        }

                        if bytesWritten < remainingDataToWrite.count {
                            await log.debug(
                                "Partial write: \(bytesWritten) of \(remainingDataToWrite.count) bytes"
                            )
                            remainingDataToWrite = remainingDataToWrite.dropFirst(bytesWritten)
                        } else {
                            remainingDataToWrite.removeAll()
                        }

                        if !remainingDataToWrite.isEmpty {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    }
                }
            } catch let error as NWError where error.errorCode == 96 {
                await log.debug("Network read yielded no data, waiting...")
                consecutiveEmptyReads += 1
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                if let nwError = error as? NWError,
                    nwError.errorCode == 57
                        || nwError.errorCode == 54
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
