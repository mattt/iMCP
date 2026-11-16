import Foundation
import UIKit

/// Runs work under a UIKit background-task assertion, so iOS doesn't suspend the app
/// while the work holds a SQLite lock. Suspending a process that holds a lock in a
/// file iOS considers shared, or in the middle of a write, risks a 0xdead10cc kill.
///
/// If iOS expires the assertion, the work is cancelled. `MobileOutbox.enqueue`
/// checks for cancellation inside its transaction and rolls back, and its
/// transactions are synchronous, so none is open across a suspension point.
enum BackgroundWork {
    @discardableResult
    static func run<T: Sendable>(_ name: String, _ operation: @escaping @Sendable () async -> T) async -> T {
        let work = Task { await operation() }
        let assertion = await MainActor.run {
            Assertion(name: name) { work.cancel() }
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        await assertion.end()
        return result
    }

    /// The throwing form of `run`.
    static func attempt<T: Sendable>(
        _ name: String, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let result: Result<T, Error> = await run(name) {
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        return try result.get()
    }

    @MainActor
    private final class Assertion {
        private var identifier = UIBackgroundTaskIdentifier.invalid

        init(name: String, onExpiry: @escaping @Sendable () -> Void) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                onExpiry()
                self?.end()
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
