import AppKit
import Foundation
import SwiftUI

/// Whether the setup wizard should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing, by choosing Finish Later,
/// or by closing its window,
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

/// Shows the setup wizard's window, and brings it to the front if it is already open.
///
/// The app has no Dock icon, so this follows the About window's controller pattern
/// rather than a SwiftUI `Window` scene, which the system may not present for an accessory app.
/// Every way the window closes records the wizard as seen:
/// Done, Finish Later, and the window's close button.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var hostingView: NSHostingView<AnyView>?
    private var onSeen: (() -> Void)?

    convenience init() {
        self.init(window: nil)
    }

    /// Shows `content` in the window, and calls `onSeen` once when the window closes.
    func show(_ content: some View, onSeen: @escaping () -> Void) {
        self.onSeen = onSeen
        let rootView = AnyView(content)

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            self.hostingView = hostingView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Set Up iMCP"
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let onSeen = self.onSeen
        self.onSeen = nil
        onSeen?()
    }
}
