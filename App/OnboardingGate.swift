import AppKit
import OSLog
import Combine
import Foundation
import SwiftUI

/// Whether the setup window should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing, by choosing Not Now,
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

/// Shows the setup window, and brings it to the front if it is already open.
///
/// The window is `OnboardingView.width` points wide and as tall as the current step,
/// no taller than its display, as in Ping Warden.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private static let log = Logger(subsystem: "co.dododo.iMCP", category: "onboarding.window")

    private var model: OnboardingModel?
    private var measure: ((NSSize) -> NSSize)?
    private var observations: Set<AnyCancellable> = []

    convenience init() {
        self.init(window: nil)
    }

    /// Opens the setup window for `serverController` and `isEnabled`.
    /// The first time it is the introduction; after that it resumes at the first step that is not done.
    func present(serverController: ServerController, isEnabled: Binding<Bool>) {
        let hasSeen = UserDefaults.standard.bool(forKey: OnboardingGate.seenDefaultsKey)
        let mode: OnboardingMode = hasSeen ? .finishSetup : .firstRun

        if let window, let model {
            model.reset(mode: mode)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(mode: mode, serverController: serverController, isEnabled: isEnabled)
        model.actions = OnboardingModel.Actions(
            close: { [weak self] in self?.close() },
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        )
        show(model)
    }

    func show(_ model: OnboardingModel, initialStep: OnboardingStep? = nil, extra: ((AnyView) -> AnyView)? = nil) {
        self.model = model
        if let initialStep { model.jump(to: initialStep) }
        let window = Self.makeWindow(model: model, extra: extra)
        window.delegate = self
        self.window = window
        self.measure = { [weak self] proposal in
            (self?.window?.contentViewController as? NSHostingController<AnyView>)?.sizeThatFits(in: proposal)
                ?? proposal
        }
        fit(animate: false)
        window.center()
        // Steps and their content change through the model and the server. Fit after the change lands.
        observations = []
        model.objectWillChange
            .merge(with: model.serverController.objectWillChange)
            .sink { [weak self] _ in Task { @MainActor in self?.fit(animate: true) } }
            .store(in: &observations)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A titled window with a transparent title bar around the setup view.
    static func makeWindow(model: OnboardingModel, extra: ((AnyView) -> AnyView)? = nil) -> NSWindow {
        var root = AnyView(OnboardingView(model: model))
        if let extra { root = extra(root) }
        let controller = NSHostingController(rootView: root)
        // The window owns its size and fits it to each step. Following the controller's
        // preferred size can loop AppKit's layout on a display shorter than a step.
        controller.sizingOptions = []
        let initialSize = NSSize(width: OnboardingView.width, height: OnboardingView.minimumContentHeight)
        controller.view.frame = NSRect(origin: .zero, size: initialSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Set Up iMCP"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Opaque, so a window that is a little taller than its step shows the window's own background
        // with its real rounded corners, not a transparent strip above square-cornered content.
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        return window
    }

    /// Size the window to its current step, no taller than the visible part of its display,
    /// keeping the top edge in place. A step that doesn't fit scrolls inside the window.
    func fit(animate: Bool) {
        guard let window, let measure, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let available = window.contentRect(forFrameRect: visible).height
        let fitting = measure(NSSize(width: OnboardingView.width, height: available))
        let size = NSSize(width: OnboardingView.width, height: min(ceil(fitting.height), available))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard frame.size != window.frame.size else { return }
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        let animates = animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animates)
        Self.log.notice(
            """
            fit step \(self.model?.step.rawValue ?? "?", privacy: .public): fitting \(NSStringFromSize(fitting), privacy: .public), \
            available \(available, privacy: .public), size \(NSStringFromSize(size), privacy: .public), \
            frame \(NSStringFromRect(frame), privacy: .public), \
            contentView \(NSStringFromRect(window.contentView?.frame ?? .zero), privacy: .public), \
            contentLayoutRect \(NSStringFromRect(window.contentLayoutRect), privacy: .public)
            """
        )
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fit(animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing is Not Now: the introduction does not open on its own again.
        UserDefaults.standard.set(true, forKey: OnboardingGate.seenDefaultsKey)
        model?.windowWillClose()
        model = nil
        measure = nil
        observations = []
        window = nil
    }
}
