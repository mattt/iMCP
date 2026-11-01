/// Errors thrown by ``StdioProxy`` I/O handlers.
enum StdioProxyError: Swift.Error {
    case connectionClosed
}

/// Chooses whether `imcp-server` should exit or retry after a stdio-proxy session.
enum MCPServiceLoop {
    enum Decision: Equatable {
        case terminate
        case reconnect(seconds: Double)
    }

    /// Returns the next action after a proxy session ends.
    ///
    /// A `nil` error means the proxy returned normally, which happens when the
    /// MCP client closed stdin. Reconnecting in that state opens and drops
    /// connections to the app in a tight loop until the process is killed.
    ///
    /// After the proxy reads anything from the client,
    /// the session belongs to the connection that carried it.
    /// The app approves a connection when the client initializes,
    /// and a new connection has no approval,
    /// so the client's later requests would fail on it.
    /// `imcp-server` exits instead, so that the client starts it again
    /// and initializes a new connection, which asks for approval.
    ///
    /// - Parameters:
    ///   - error: The error that ended the session, if any.
    ///   - hasReadClientInput: Whether the proxy read anything from stdin.
    static func decision(error: (any Error)?, hasReadClientInput: Bool) -> Decision {
        guard let error, !hasReadClientInput else {
            return .terminate
        }

        if error is CancellationError || error is MCPStdinFrames.Failure {
            return .terminate
        }

        if let proxyError = error as? StdioProxyError {
            switch proxyError {
            case .connectionClosed:
                return .terminate
            }
        }

        return .reconnect(seconds: 5)
    }
}
