import Foundation
import MCP
import Network

// MARK: - Policy

/// The rules for requests that arrive through a public HTTPS tunnel
/// (Tailscale Funnel or Cloudflare Tunnel).
///
/// Both forward public HTTPS traffic to a loopback port on this Mac,
/// so the server sees every request as coming from 127.0.0.1.
/// A loopback address says nothing about who sent the request,
/// and the tunnel doesn't identify the sender, so none of the tailnet checks apply.
/// Every request is internet traffic:
/// it needs an access token, only active public host names are accepted,
/// and the request and connection sizes are small.
///
/// A request may also carry a short-lived OAuth access token that iMCP's own authorization server issued
/// for this endpoint. See `OAuthAuthority`.
enum FunnelPolicy {
    /// Open connections that the funnel listener serves at one time.
    /// Tailnet connections have their own limit, so that internet traffic can't starve them.
    static let maximumConnections = 16
    /// How long a connection can wait for the next request.
    static let idleTimeout: Duration = .seconds(60)
    /// How long a request can take to arrive, from its first byte.
    static let requestDeadline: Duration = .seconds(15)

    /// The `Host` and `Origin` values that a request may use:
    /// the public name on port 443, which clients write without a port.
    static func originValidator(host: String) -> OriginValidator {
        originValidator(hosts: [host])
    }

    /// The `Host` and `Origin` values that a request may use across one or more active public hosts.
    static func originValidator<S: Sequence>(hosts: S) -> OriginValidator where S.Element == String {
        let normalized = Set(hosts.map(normalizedHost).filter { !$0.isEmpty }).sorted()
        var allowedHosts: [String] = []
        var allowedOrigins: [String] = []
        for host in normalized {
            allowedHosts.append(host)
            allowedHosts.append("\(host):443")
            allowedOrigins.append("https://\(host)")
        }
        return OriginValidator(
            allowedHosts: allowedHosts,
            allowedOrigins: allowedOrigins
        )
    }

    /// Returns the matching normalized host from `allowedHosts` for a request's `Host` header, if any.
    static func matchedHost(in hostHeader: String?, allowedHosts: Set<String>) -> String? {
        guard let hostHeader else { return nil }
        var candidate = hostHeader.trimmingCharacters(in: .whitespaces).lowercased()
        if candidate.hasSuffix(":443") {
            candidate.removeLast(4)
        }
        candidate = normalizedHost(candidate)
        return allowedHosts.contains(candidate) ? candidate : nil
    }

    /// Whether a Funnel failure message indicates a missing `funnel` ACL capability in the tailnet policy.
    static func isMissingFunnelACLError(_ message: String) -> Bool {
        let lower = message.lowercased()
        let markers = ["funnel", "capability", "nodeattr", "acl", "permission", "not allowed", "unauthorized"]
        return markers.contains { lower.contains($0) }
    }

    /// A Tailscale ACL `nodeAttrs` snippet granting the `funnel` capability to `ipv4Address`.
    static func tailscaleNodeAttrsSnippet(ipv4Address: String) -> String {
        """
        "nodeAttrs": [
          {
            "target": ["\(ipv4Address)"],
            "attr": ["funnel"]
          }
        ]
        """
    }

    /// The public URL of the MCP endpoint.
    static func publicURL(host: String) -> String {
        "https://\(host)/mcp"
    }

    /// The host name from the node, in the form that clients send:
    /// lowercase, without a trailing dot.
    static func normalizedHost(_ name: String) -> String {
        var host = name.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    enum Decision: Equatable {
        case allowed(AccessToken)
        /// An OAuth access token that iMCP issued for the MCP endpoint.
        case allowedOAuth(OAuthGrant)
        /// No token, or a token that iMCP doesn't know.
        case unauthorized
        /// Too many requests with bad tokens lately.
        case rateLimited(retryAfter: Int)
        /// The token belongs to a device on the tailnet.
        /// Funnel can't tell which device sent a request, so it can't honor that binding.
        case boundToDevice
    }

    /// Decides whether a request may continue.
    ///
    /// The decision depends only on the request's `Authorization` field.
    /// Nothing about the connection, such as its address or a whois answer, can stand in for a token.
    /// A request with a good token always passes, so people who send bad tokens can't lock the owner out.
    static func authorize(
        authorizationField: String?,
        lookup: (String) -> AccessToken?,
        oauthLookup: (String) -> OAuthGrant? = { _ in nil },
        limiter: inout FailedAuthLimiter,
        now: Date = Date()
    ) -> Decision {
        if let token = bearerToken(in: authorizationField).flatMap(lookup) {
            return token.boundDevice == nil ? .allowed(token) : .boundToDevice
        }
        if let grant = bearerToken(in: authorizationField).flatMap(oauthLookup) {
            return .allowedOAuth(grant)
        }
        if let retryAfter = limiter.retryAfter(now: now) {
            return .rateLimited(retryAfter: retryAfter)
        }
        limiter.recordFailure(now: now)
        return .unauthorized
    }

    /// The secret in an `Authorization: Bearer` field.
    static func bearerToken(in field: String?) -> String? {
        guard let field else { return nil }
        let parts = field.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Whether to close the connection after a response.
    /// A client that fails a check doesn't get to keep trying on the same connection.
    static func closesConnection(afterStatus status: Int) -> Bool {
        [401, 403, 429].contains(status)
    }
}

/// Counts requests with bad tokens, and blocks more of them for a while after too many.
///
/// Funnel hides the sender's address, so the count covers all senders together.
/// Blocking only changes the answer to a request that has no good token,
/// so it can't keep the owner out.
struct FailedAuthLimiter: Equatable, Sendable {
    var maximumFailures = 10
    var window: TimeInterval = 60
    var blockDuration: TimeInterval = 60

    private var failures: [Date] = []
    private var blockedUntil: Date?

    init(maximumFailures: Int = 10, window: TimeInterval = 60, blockDuration: TimeInterval = 60) {
        self.maximumFailures = maximumFailures
        self.window = window
        self.blockDuration = blockDuration
    }

    mutating func recordFailure(now: Date = Date()) {
        failures.removeAll { now.timeIntervalSince($0) >= window }
        failures.append(now)
        if failures.count >= maximumFailures {
            blockedUntil = now.addingTimeInterval(blockDuration)
            failures.removeAll()
        }
    }

    /// The whole seconds until requests with bad tokens may try again, or `nil` if they may now.
    func retryAfter(now: Date = Date()) -> Int? {
        guard let blockedUntil, blockedUntil > now else { return nil }
        return max(1, Int(blockedUntil.timeIntervalSince(now).rounded(.up)))
    }
}

// MARK: - Local listener

/// A listener on 127.0.0.1 that Funnel forwards public connections to.
protocol LocalForwardListener: TailnetListener {
    var port: UInt16 { get }
    /// Stops listening and ends `accept()`.
    func shutdown()
}

/// Listens on 127.0.0.1 at a port that the system picks.
///
/// Only this Mac can reach the port, and so can any process on it.
/// The server treats those connections like internet traffic.
final class LoopbackListener: LocalForwardListener, @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let connections: AsyncStream<NWConnection>

    private init(
        listener: NWListener,
        port: UInt16,
        queue: DispatchQueue,
        connections: AsyncStream<NWConnection>
    ) {
        self.listener = listener
        self.port = port
        self.queue = queue
        self.connections = connections
        iterator = connections.makeAsyncIterator()
    }

    private let lock = NSLock()
    private var iterator: AsyncStream<NWConnection>.AsyncIterator?

    static func start() async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "iMCP.RemoteAccess.Loopback")
        let (stream, continuation) = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingNewest(64))
        listener.newConnectionHandler = { connection in
            // A full buffer drops the oldest connection, which closes it when it's released.
            if case .dropped(let dropped) = continuation.yield(connection) { dropped.cancel() }
            connection.start(queue: queue)
        }
        continuation.onTermination = { _ in listener.cancel() }

        let port: UInt16 = try await withCheckedThrowingContinuation { resume in
            let once = ResumeOnce(resume)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        once.resume(.success(port))
                    } else {
                        once.resume(.failure(POSIXError(.EADDRNOTAVAIL)))
                    }
                case .failed(let error):
                    once.resume(.failure(error))
                    continuation.finish()
                case .cancelled:
                    once.resume(.failure(CancellationError()))
                    continuation.finish()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let result = LoopbackListener(listener: listener, port: port, queue: queue, connections: stream)
        result.continuation = continuation
        return result
    }

    private var continuation: AsyncStream<NWConnection>.Continuation?

    func accept() async throws -> any TailnetConnection {
        var iterator = lock.withLock { self.iterator }
        let next = await iterator?.next()
        lock.withLock { self.iterator = iterator }
        guard let next else { throw CancellationError() }
        return LoopbackConnection(connection: next, queue: queue)
    }

    func shutdown() {
        continuation?.finish()
        listener.cancel()
    }
}

/// A connection that Funnel forwarded.
/// Its sender is unknown, so `remoteAddress` is `nil`.
private final class LoopbackConnection: TailnetConnection, @unchecked Sendable {
    let remoteAddress: String? = nil
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func receive(timeout: Duration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                queue.asyncAfter(deadline: .now() + timeout.seconds) {
                    once.resume(.failure(POSIXError(.ETIMEDOUT)))
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                    if let error {
                        once.resume(.failure(error))
                    } else {
                        // No data means that the peer closed the connection.
                        once.resume(.success(data ?? Data()))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            queue.asyncAfter(deadline: .now() + timeout.seconds) {
                once.resume(.failure(POSIXError(.ETIMEDOUT)))
            }
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        once.resume(.failure(error))
                    } else {
                        once.resume(.success(()))
                    }
                }
            )
        }
    }

    func close() async {
        connection.cancel()
    }
}

/// Resumes a continuation the first time that anything asks, and ignores the rest.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
