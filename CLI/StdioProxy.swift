import Dispatch
import Logging
import MCP
import SystemPackage

import struct Foundation.Data

/// A proxy between standard I/O and a connected socket to the iMCP app.
actor StdioProxy {
    private let channel: DispatchIO
    private let queue = DispatchQueue(label: "me.mattt.iMCP.server.socket")
    private let stdinBufferSize: Int
    private var isRunning = false

    /// Whether the proxy has read anything from stdin.
    ///
    /// Once it has, the session belongs to this connection,
    /// and `imcp-server` must not continue it on another one.
    private(set) var hasReadInput = false

    /// Creates a proxy that forwards stdin to `socket` and socket data to stdout.
    ///
    /// The proxy owns `socket` and closes it when it stops.
    ///
    /// - Parameters:
    ///   - socket: A socket connected to an app that passed the code-signing check.
    ///   - stdinBufferSize: Buffer size for reading from stdin.
    init(socket: Int32, stdinBufferSize: Int = 10 * 1024 * 1024) {
        self.channel = DispatchIO(type: .stream, fileDescriptor: socket, queue: queue) { _ in
            close(socket)
        }
        self.channel.setLimit(lowWater: 1)
        self.stdinBufferSize = stdinBufferSize
    }

    /// Sends `hello`, then relays messages until either side closes.
    func start(hello: Data) async throws {
        guard !isRunning else { return }
        isRunning = true

        do {
            try await write(hello)
            try await relay()
        } catch {
            await stop()
            throw error
        }
        await stop()
    }

    private func relay() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [stdinBufferSize] in
                do {
                    try await self.handleStdinToSocket(bufferSize: stdinBufferSize)
                } catch {
                    await log.error("Stdin handler failed: \(error)")
                    throw error
                }
            }

            group.addTask {
                do {
                    try await self.handleSocketToStdout()
                } catch {
                    await log.error("Socket handler failed: \(error)")
                    throw error
                }
            }

            // Wait for either task to finish or fail.
            // Closing the channel ends a pending socket read,
            // and cancellation ends the stdin loop's sleep.
            let firstError: (any Swift.Error)?
            do {
                try await group.next()
                firstError = nil
            } catch {
                firstError = error
            }
            await self.stop()
            group.cancelAll()
            if let firstError {
                throw firstError
            }
        }
    }

    /// Stops the proxy and closes the socket.
    func stop() async {
        isRunning = false
        channel.close(flags: .stop)
    }

    private func write(_ data: Data) async throws {
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            channel.write(offset: 0, data: payload, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: StdioProxyError.connectionClosed)
                }
            }
        }
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

    private func handleStdinToSocket(bufferSize: Int) async throws {
        let stdin = FileDescriptor.standardInput
        try setNonBlocking(fileDescriptor: stdin)

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var frames = MCPStdinFrames()

        while true {
            guard isRunning else {
                await log.debug("Connection no longer active, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            let bytesRead: Int
            do {
                bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdin.read(into: UnsafeMutableRawBufferPointer(pointer))
                }
            } catch let error as Errno where error == .wouldBlock {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }

            if bytesRead == 0 {
                // The MCP client closed stdin. Exit rather than return:
                // a clean return made MCPService reconnect in a tight loop
                // while stdin stayed at EOF.
                await log.debug("EOF reached on stdin, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            hasReadInput = true
            for frame in try frames.append(Data(buffer[0 ..< bytesRead])) {
                try await write(frame)
                await log.debug("Sent \(frame.count) bytes to iMCP")
            }
        }
    }

    private func handleSocketToStdout() async throws {
        let chunks = AsyncThrowingStream<DispatchData, Swift.Error> { continuation in
            channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
                if let data, !data.isEmpty {
                    continuation.yield(data)
                }
                guard done else { return }
                if error == 0 || error == ECANCELED {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: Errno(rawValue: error))
                }
            }
        }

        do {
            for try await chunk in chunks {
                await log.debug("Received \(chunk.count) bytes from iMCP")
                try await writeToStdout(Data(chunk))
            }
        } catch is Errno {
            // The app reset the connection.
        }

        await log.debug("iMCP closed the connection")
        throw StdioProxyError.connectionClosed
    }

    private func writeToStdout(_ data: Data) async throws {
        let stdout = FileDescriptor.standardOutput
        var remaining = data[...]
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { try stdout.write($0) }
                remaining = remaining.dropFirst(written)
            } catch let error as Errno where error == .wouldBlock {
                // Stdout can share a nonblocking file description with stdin.
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}
