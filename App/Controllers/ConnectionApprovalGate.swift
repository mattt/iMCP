import MCP

/// The approval state of one MCP connection.
///
/// The SDK runs each request in its own task
/// and returns from `Server.start(transport:initializeHook:)`
/// before the client sends `initialize`.
/// A client can send other requests before `initialize`,
/// or while its `initialize` waits for the user to decide.
/// The gate records the decision so that handlers can refuse those requests.
actor ConnectionApprovalGate {
    private enum State {
        case pending
        case deciding
        case approved
        case denied
    }

    private var state = State.pending

    /// Asks for a decision on the first `initialize` of the connection.
    ///
    /// Only the first call runs `decide`.
    /// Later calls throw without asking,
    /// whether the first decision is pending, approved, or denied.
    ///
    /// - Throws: `MCPError.connectionClosed` if `decide` denies the connection,
    ///   or `MCPError.invalidRequest` if a decision was already requested.
    func approve(using decide: @Sendable () async -> Bool) async throws {
        guard state == .pending else {
            throw MCPError.invalidRequest("Connection approval was already requested")
        }

        state = .deciding
        let approved = await decide()
        state = approved ? .approved : .denied

        guard approved else {
            throw MCPError.connectionClosed
        }
    }

    /// Whether the user approved the connection.
    var isApproved: Bool {
        state == .approved
    }

    /// Throws unless the user approved the connection.
    func requireApproval() throws {
        guard isApproved else {
            throw MCPError.invalidRequest("Connection is not approved")
        }
    }
}

extension MCP.Server {
    /// Starts the server and registers handlers
    /// only after the user approves the connection.
    ///
    /// - Parameters:
    ///   - transport: The transport for the connection.
    ///   - gate: The approval state of the connection.
    ///   - approve: Asks the user to approve the client. Runs at most once.
    ///   - registerHandlers: Registers the handlers. Runs only after approval.
    func start(
        transport: any Transport,
        gate: ConnectionApprovalGate,
        approve: @escaping @Sendable (Client.Info) async -> Bool,
        registerHandlers: @escaping @Sendable () async -> Void
    ) async throws {
        try await start(transport: transport) { clientInfo, _ in
            try await gate.approve { await approve(clientInfo) }
            await registerHandlers()
        }
    }

    /// Sends `notification` only if the user approved the connection.
    ///
    /// A connection that waits for approval has no handlers,
    /// so it must not learn that iMCP's tools changed.
    ///
    /// - Returns: Whether the server sent the notification.
    @discardableResult
    func notify<N: MCP.Notification>(
        _ notification: Message<N>,
        ifApprovedBy gate: ConnectionApprovalGate
    ) async throws -> Bool {
        guard await gate.isApproved else { return false }
        try await notify(notification)
        return true
    }

    /// Registers a handler that refuses requests
    /// until the user approves the connection.
    @discardableResult
    func withApprovedMethodHandler<M: Method>(
        _ type: M.Type,
        gate: ConnectionApprovalGate,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        withMethodHandler(type) { parameters in
            try await gate.requireApproval()
            return try await handler(parameters)
        }
    }
}
