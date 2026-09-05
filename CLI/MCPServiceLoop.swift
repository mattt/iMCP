import Network

/// Errors thrown by ``StdioProxy`` I/O handlers.
enum StdioProxyError: Swift.Error {
    case networkTimeout
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
    /// Bonjour connections in a tight loop until the process is killed.
    static func decision(error: (any Error)?) -> Decision {
        guard let error else {
            return .terminate
        }

        if error is CancellationError {
            return .terminate
        }

        if let proxyError = error as? StdioProxyError {
            switch proxyError {
            case .networkTimeout:
                return .reconnect(seconds: 1)
            case .connectionClosed:
                return .terminate
            }
        }

        if let nwError = error as? NWError,
            nwError.errorCode == 54 || nwError.errorCode == 57
        {
            return .terminate
        }

        return .reconnect(seconds: 5)
    }
}
