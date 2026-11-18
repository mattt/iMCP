import AppKit
import Sparkle
import SwiftUI

/// The size of the Settings window.
enum SettingsWindowMetrics {
    static let defaultSize = NSSize(width: 760, height: 560)
    static let minimumSize = NSSize(width: 640, height: 440)
    static let autosaveName = "iMCPSettingsWindow"
}

/// What the Settings window shows, with the menu bar state read live from the app delegate.
private struct SettingsRoot: View {
    @ObservedObject var serverController: ServerController
    let appDelegate: AppDelegate
    let updater: SPUUpdater

    var body: some View {
        SettingsView(
            serverController: serverController,
            isMenuBarExtraInserted: appDelegate.isMenuBarExtraInserted,
            updater: updater
        )
    }
}

/// Owns the Settings window.
///
/// It is a plain window with a unified toolbar and a full-size content view, as in Ping Warden,
/// so the sidebar starts under the traffic lights, the sidebar button sits in the toolbar,
/// and the pane's title is the window's title. The Settings scene gave a different window,
/// with a gap above the content and a sidebar button inside the sidebar.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var serverController: ServerController?
    private var appDelegate: AppDelegate?
    private var updater: SPUUpdater?
    private(set) var window: NSWindow?

    /// Gives the controller what the window shows. App launch calls this before anything opens Settings.
    func configure(serverController: ServerController, appDelegate: AppDelegate, updater: SPUUpdater) {
        self.serverController = serverController
        self.appDelegate = appDelegate
        self.updater = updater
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = makeWindow(restoresFrame: true) else { return }
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        Self.clearInitialFocus(in: window)
    }

    /// A window gives its first text field the focus when it opens, which shows that field's text selected.
    /// Nothing in Settings should start out being edited.
    static func clearInitialFocus(in window: NSWindow) {
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    /// Builds the window. Debug screenshots build it too, so they draw the same structure.
    func makeWindow(restoresFrame: Bool) -> NSWindow? {
        guard let serverController, let appDelegate, let updater else { return nil }
        let hosting = NSHostingController(
            rootView: SettingsRoot(serverController: serverController, appDelegate: appDelegate, updater: updater)
        )
        // The window owns its size. The root view's minimum frame bounds it.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: SettingsWindowMetrics.defaultSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.title = "Settings"
        window.contentViewController = hosting
        window.contentMinSize = SettingsWindowMetrics.minimumSize
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.center()
        // Attaching the name restores a saved frame, so center first.
        if restoresFrame { window.setFrameAutosaveName(SettingsWindowMetrics.autosaveName) }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
