import AppKit
import Foundation
import SwiftUI

/// Whether the setup wizard should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing, by choosing Finish Later,
/// or by closing its window,
/// it never opens on its own again. "Set Up iMCP…" in the menu or Settings still opens it.
enum OnboardingGate {
    static let seenDefaultsKey = "hasSeenOnboarding"

    static func shouldOpenAutomatically(
        hasSeenOnboarding: Bool,
        hasTrustedClient: Bool,
        hasConnectedBefore: Bool,
        hasServiceOnBeyondDefaults: Bool
    ) -> Bool {
        !hasSeenOnboarding && !hasTrustedClient && !hasConnectedBefore && !hasServiceOnBeyondDefaults
    }
}

/// Shows the setup wizard's window, and brings it to the front if it is already open.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var hostingView: NSHostingView<AnyView>?
    private var onSeen: (() -> Void)?

    convenience init() {
        self.init(window: nil)
    }

    /// Opens the setup wizard for `serverController` and `isEnabled`.
    func present(serverController: ServerController, isEnabled: Binding<Bool>) {
        let markSeen = {
            UserDefaults.standard.set(true, forKey: OnboardingGate.seenDefaultsKey)
        }
        let view = OnboardingWizardView(
            serverController: serverController,
            isEnabled: isEnabled,
            onFinish: { [weak self] in
                markSeen()
                self?.close()
            }
        )
        show(view, onSeen: markSeen)
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
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 590),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up iMCP"
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onSeen?()
        onSeen = nil
    }
}
