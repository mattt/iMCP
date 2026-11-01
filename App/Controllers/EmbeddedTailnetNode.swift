import Darwin
import Foundation
import OSLog
import TailscaleKit

private let log = Logger.server

/// iMCP's own Tailscale node, embedded with TailscaleKit.
///
/// The node has its own identity and address on the tailnet,
/// so no other process on the Mac can listen on that address.
/// It keeps its keys in the state directory, so it stays logged in between launches.
final class EmbeddedTailnetNode: TailnetNode {
    private let node: TailscaleNode
    private let handle: TailscaleHandle
    private let logPipe: GoLogPipe

    private init(node: TailscaleNode, handle: TailscaleHandle, logPipe: GoLogPipe) {
        self.node = node
        self.handle = handle
        self.logPipe = logPipe
    }

    /// Starts a node.
    /// It joins the tailnet if it's logged in,
    /// and otherwise asks the control server for a login URL.
    static func start(_ configuration: TailnetNodeConfiguration) async throws -> EmbeddedTailnetNode {
        try FileManager.default.createDirectory(
            at: configuration.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let logPipe = GoLogPipe()
        let nodeConfiguration = TailscaleKit.Configuration(
            hostName: configuration.hostname,
            path: configuration.stateDirectory.path,
            authKey: configuration.authKey,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )
        do {
            let node = try await blocking {
                try TailscaleNode(config: nodeConfiguration, logger: logPipe)
            }
            guard let handle = await node.tailscale else {
                throw TailscaleError.badInterfaceHandle
            }
            return EmbeddedTailnetNode(node: node, handle: handle, logPipe: logPipe)
        } catch {
            logPipe.close()
            throw error
        }
    }

    func status() async throws -> TailnetStatus {
        let data = try await blocking { try await node.statusJSON() }
        return try TailnetStatus(json: data)
    }

    func whois(_ address: String) async throws -> TailnetPeer {
        let response = try await blocking { try await node.whois(address) }.Node
        let name = try? await status().peerNames[response.StableID]
        return TailnetPeer(
            stableID: response.StableID,
            deviceName: name ?? address,
            userID: response.User,
            isTagged: !(response.Tags ?? []).isEmpty
        )
    }

    func listen(on address: String, port: UInt16) async throws -> any TailnetListener {
        let handle = self.handle
        let listener = try await blocking {
            try await Listener(tailscale: handle, proto: .tcp, address: "\(address):\(port)")
        }
        return EmbeddedTailnetListener(listener: listener)
    }

    func logout() async throws {
        try await blocking { try await node.logout() }
    }

    func close() async {
        do {
            try await blocking { try await node.close() }
        } catch {
            log.error("Couldn't close the remote access node: \(error)")
        }
        logPipe.close()
    }
}

private struct EmbeddedTailnetListener: TailnetListener {
    /// How long one accept waits.
    /// TailscaleKit closes the listener when an accept times out,
    /// and the server then listens again.
    static let acceptTimeout: TimeInterval = 24 * 60 * 60

    let listener: Listener

    func accept() async throws -> any TailnetConnection {
        let connection = try await blocking { try await listener.accept(timeout: Self.acceptTimeout) }
        return EmbeddedTailnetConnection(connection: connection, remoteAddress: await connection.remoteAddress)
    }
}

private struct EmbeddedTailnetConnection: TailnetConnection {
    let connection: IncomingConnection
    let remoteAddress: String?

    func receive(timeout: Duration) async throws -> Data {
        let milliseconds = timeout.milliseconds
        return try await blocking {
            try await connection.receive(maximumLength: 64 * 1024, timeout: milliseconds)
        }
    }

    func send(_ data: Data, timeout: Duration) async throws {
        let milliseconds = timeout.milliseconds
        try await blocking { try await connection.send(data, timeout: milliseconds) }
    }

    func close() async {
        await blocking { await connection.close() }
    }
}

// MARK: - Blocking calls

/// Runs TailscaleKit's calls on threads outside the cooperative pool.
///
/// TailscaleKit's listener, connections, and node wait in `poll(2)`
/// and other blocking calls on their actors.
/// Those actors don't have custom executors,
/// so they run on this executor when the calling task prefers it,
/// and an idle connection doesn't hold one of the pool's few threads.
private final class BlockingCallExecutor: TaskExecutor {
    static let shared = BlockingCallExecutor()

    private let queue = DispatchQueue(
        label: "iMCP.RemoteAccess.Tailscale",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }
}

private func blocking<T, Failure: Error>(_ operation: () async throws(Failure) -> T) async throws(Failure) -> T {
    try await withTaskExecutorPreference(BlockingCallExecutor.shared, operation: operation)
}

extension Duration {
    /// The duration in whole milliseconds, as TailscaleKit's timeouts take it.
    fileprivate var milliseconds: Int32 {
        let (seconds, attoseconds) = components
        return Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Logs

/// Sends the node's logs to the unified log at the debug level.
///
/// The Go side gets its own copy of the pipe's write end, which it may close at any time.
private final class GoLogPipe: LogSink, @unchecked Sendable {
    let logFileHandle: Int32?
    private let pipe = Pipe()

    init() {
        let descriptor = dup(pipe.fileHandleForWriting.fileDescriptor)
        if descriptor >= 0 {
            // A write after the read end closes fails with EPIPE instead of raising SIGPIPE.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            logFileHandle = descriptor
        } else {
            logFileHandle = nil
        }
        try? pipe.fileHandleForWriting.close()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                Logger.server.debug("Tailscale: \(line, privacy: .private)")
            }
        }
    }

    func log(_ message: String) {
        Logger.server.debug("TailscaleKit: \(message, privacy: .private)")
    }

    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
    }
}
