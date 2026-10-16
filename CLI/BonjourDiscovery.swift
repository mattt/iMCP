import Network

/// Guards a continuation so it is resumed exactly once.
actor ConnectionState {
    private var hasResumed = false

    func checkAndSetResumed() -> Bool {
        if !hasResumed {
            hasResumed = true
            return true
        }
        return false
    }
}

/// Finds a Bonjour endpoint with a browser,
/// and guarantees the browser is cancelled afterwards.
///
/// Every `NWBrowser` that has been started holds a `DNSServiceBrowse` connection
/// to `mDNSResponder` until it is cancelled.
/// `imcp-server` retries discovery in a loop,
/// so a browser left running on any exit path leaks one connection per attempt (#192).
enum BonjourDiscovery {
    enum Error: Swift.Error {
        case timeout
    }

    /// Starts `browser` on the main queue
    /// and returns the first service on this Mac that satisfies `preferring`,
    /// or the first service on this Mac if none does.
    /// Services on other Macs are ignored (#257).
    ///
    /// The browser is cancelled before this function returns or throws,
    /// whether a result was found, the browser failed, or `timeout` elapsed.
    static func discoverEndpoint(
        using browser: NWBrowser,
        timeout: Duration,
        preferring isPreferred: @escaping @Sendable (NWBrowser.Result) -> Bool
    ) async throws -> NWEndpoint {
        defer { browser.cancel() }

        let state = ConnectionState()
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try await Task.sleep(for: timeout)
                if await state.checkAndSetResumed() {
                    continuation.resume(throwing: Error.timeout)
                }
            }

            browser.stateUpdateHandler = { browserState in
                guard case .failed(let error) = browserState else { return }
                Task {
                    if await state.checkAndSetResumed() {
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard let selected = select(from: results, isLocal: isLocal, preferring: isPreferred) else { return }
                Task {
                    if await state.checkAndSetResumed() {
                        timeoutTask.cancel()
                        continuation.resume(
                            returning: connectionEndpoint(for: selected.endpoint, metadata: selected.metadata)
                        )
                    }
                }
            }

            browser.start(queue: .main)
        }
    }

    /// Returns the first local result that satisfies `preferring`,
    /// or the first local result if none does.
    static func select<Result>(
        from results: some Collection<Result>,
        isLocal: (Result) -> Bool,
        preferring isPreferred: (Result) -> Bool
    ) -> Result? {
        let local = results.filter(isLocal)
        return local.first(where: isPreferred) ?? local.first
    }

    /// Returns whether `result` is a service advertised by this Mac.
    ///
    /// Bonjour reports a service registered on this Mac on the loopback interface,
    /// and a service from another Mac only on network interfaces.
    /// iMCP on another Mac accepts connections over its own loopback only (#242),
    /// and its advertised port is meaningless here,
    /// because the connection goes to this Mac's loopback address (#229).
    static func isLocal(_ result: NWBrowser.Result) -> Bool {
        result.interfaces.contains { $0.type == .loopback }
    }

    static func connectionEndpoint(
        for serviceEndpoint: NWEndpoint,
        metadata: NWBrowser.Result.Metadata
    ) -> NWEndpoint {
        guard case .bonjour(let record) = metadata,
            let value = record["port"],
            let number = UInt16(value),
            number > 0,
            let port = NWEndpoint.Port(rawValue: number)
        else {
            return serviceEndpoint
        }

        // Avoid service resolution selecting a Docker bridge address (#142).
        return .hostPort(host: .ipv4(.loopback), port: port)
    }
}
