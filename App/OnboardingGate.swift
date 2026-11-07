import Foundation

/// Whether the setup wizard should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing or by choosing Finish Later,
/// it never opens on its own again; "Set Up iMCP…" in the menu still opens it.
/// An install that was already set up before the wizard existed counts as seen:
/// a trusted client, a past connection, or a service on beyond the defaults
/// (Maps, and Utilities where it is listed) each show that setup already happened.
enum OnboardingGate {
    static func shouldOpenAutomatically(
        hasSeenOnboarding: Bool,
        hasTrustedClient: Bool,
        hasConnectedBefore: Bool,
        hasServiceOnBeyondDefaults: Bool
    ) -> Bool {
        !hasSeenOnboarding && !hasTrustedClient && !hasConnectedBefore && !hasServiceOnBeyondDefaults
    }
}

/// The setup wizard's sample lookup, which must end at its deadline.
enum OnboardingLookup {
    /// The result of `operation`, or nil when it throws,
    /// when it does not finish within `limit`, or when the caller is cancelled.
    ///
    /// The first outcome wins and cancels the rest.
    /// This returns at the deadline even when `operation` ignores cancellation,
    /// so a slow lookup cannot keep the wizard waiting; its late result is dropped.
    static func result<T: Sendable>(
        within limit: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(
                    continuation,
                    tasks: [
                        Task { race.finish(try? await operation()) },
                        Task {
                            try? await Task.sleep(for: limit)
                            race.finish(nil)
                        },
                    ]
                )
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// The shared state of one lookup: the continuation to resume once, and the tasks to cancel.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var outcome: T??

        func start(_ continuation: CheckedContinuation<T?, Never>, tasks: [Task<Void, Never>]) {
            lock.lock()
            if let outcome {
                // A task, or the caller's cancellation, finished first.
                lock.unlock()
                tasks.forEach { $0.cancel() }
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ value: T?) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = .some(value)
            let continuation = self.continuation
            let tasks = self.tasks
            self.continuation = nil
            self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: value)
        }
    }
}
