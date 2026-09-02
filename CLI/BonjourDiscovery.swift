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
    /// and returns the first result that satisfies `preferring`,
    /// or the first result at all if none does.
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
                guard let selected = results.first(where: isPreferred) ?? results.first else { return }
                Task {
                    if await state.checkAndSetResumed() {
                        timeoutTask.cancel()
                        continuation.resume(returning: selected.endpoint)
                    }
                }
            }

            browser.start(queue: .main)
        }
    }
}
