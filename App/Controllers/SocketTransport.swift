import Dispatch
import Foundation
import Logging
import MCP

/// An MCP transport over a connected socket
/// that carries newline-delimited JSON-RPC messages,
/// like the stdio transport that `imcp-server` relays.
actor SocketTransport: Transport {
    /// The longest message the transport accepts, excluding the newline.
    static let maximumMessageLength = 16 * 1024 * 1024

    nonisolated let logger: Logger

    private let channel: DispatchIO
    private let queue: DispatchQueue
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var isConnected = false
    private var isClosed = false

    /// Creates a transport that owns `descriptor` and closes it when the transport disconnects.
    init(descriptor: Int32, logger: Logger? = nil) {
        let queue = DispatchQueue(label: "me.mattt.iMCP.socket-transport")
        self.queue = queue
        self.channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            close(descriptor)
        }
        self.channel.setLimit(lowWater: 1)
        self.logger =
            logger
            ?? Logger(label: "me.mattt.iMCP.socket-transport", factory: { _ in SwiftLogNoOpLogHandler() })
        (self.messages, self.continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !isConnected else { return }
        guard !isClosed else {
            throw MCPError.transportError(POSIXError(.ENOTCONN))
        }
        isConnected = true

        // The read handler runs on the channel's serial queue,
        // so the framer sees chunks in order.
        let framer = LineFramer(maximumLength: Self.maximumMessageLength)
        let continuation = self.continuation
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty {
                do {
                    for message in try framer.append(Data(data)) {
                        continuation.yield(message)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
            guard done else { return }
            if error == 0 || error == ECANCELED {
                continuation.finish()
            } else {
                continuation.finish(
                    throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                )
            }
        }
    }

    /// Closes the socket, whether or not the transport connected.
    func disconnect() async {
        guard !isClosed else { return }
        isClosed = true
        isConnected = false
        channel.close(flags: .stop)
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(POSIXError(.ENOTCONN))
        }

        var message = data
        message.append(UInt8(ascii: "\n"))
        let payload = message.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            channel.write(offset: 0, data: payload, queue: queue) { done, _, error in
                guard done else { return }
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                    )
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messages
    }
}

/// Splits a byte stream into newline-delimited messages.
///
/// Not thread-safe: use it from one serial queue.
final class LineFramer: @unchecked Sendable {
    struct MessageTooLong: Swift.Error {}

    private let maximumLength: Int
    private var pending = Data()

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    /// Adds `data` and returns the complete, nonblank messages it finishes.
    func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let message = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard message.count <= maximumLength else { throw MessageTooLong() }
            if !message.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                messages.append(message)
            }
        }
        guard pending.count <= maximumLength else { throw MessageTooLong() }
        return messages
    }
}
