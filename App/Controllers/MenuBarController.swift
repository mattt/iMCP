import AppKit
import Sparkle
import SwiftUI

/// The menu bar item and its panel.
///
/// This is a status item with its own borderless panel, not a SwiftUI `MenuBarExtra`, because the system
/// draws a `MenuBarExtra` window with a larger corner radius than a native menu, and nothing in the window
/// lets an app change it. Here the panel's shape and position are ours, so it matches a native menu.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var root: Root?
    private var resignObserver: (any NSObjectProtocol)?
    private var lastResignClose = Date.distantPast
    private var isOn = true

    /// The width of the panel, in points.
    static let panelWidth: CGFloat = 298

    private struct Root {
        let serverController: ServerController
        let updater: SPUUpdater
        let openSettings: () -> Void
    }

    /// Remembers what the panel shows. Safe to call again.
    func install(serverController: ServerController, updater: SPUUpdater, openSettings: @escaping () -> Void) {
        guard root == nil else { return }
        root = Root(serverController: serverController, updater: updater, openSettings: openSettings)
    }

    /// Shows or removes the menu bar item. Removing it leaves the server running.
    func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle)
            statusItem = item
            item.button?.setAccessibilityLabel("iMCP")
            updateIcon(isOn: isOn)
        } else {
            close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    func updateIcon(isOn: Bool) {
        self.isOn = isOn
        statusItem?.button?.image = NSImage(named: "MenuIcon-\(isOn ? "On" : "Off")")
    }

    var isShown: Bool { panel?.isVisible == true }

    @objc private func toggle() {
        // Clicking the item while the panel is open first takes key status away from the panel, which closes it.
        // That click means "close", so it must not open the panel again.
        if isShown {
            close()
        } else if Date().timeIntervalSince(lastResignClose) > 0.25 {
            show()
        }
    }

    func close() {
        ActivityFlyout.shared.hide()
        panel?.orderOut(nil)
        statusItem?.button?.isHighlighted = false
    }

    private func show() {
        guard let root, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel(root: root)
        self.panel = panel

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let height = max(panel.frame.height, 120)
        var x = buttonFrame.minX
        x = min(x, visible.maxX - Self.panelWidth - 4)
        x = max(x, visible.minX + 4)
        let top = buttonFrame.minY - 2
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.panelWidth, height: height), display: true)
        button.isHighlighted = true
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel(root: Root) -> MenuPanel {
        let panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = Self.roundedMask(radius: MenuMetrics.panelRadius)

        let hosting = NSHostingView(
            rootView: MenuPanelRoot(
                serverController: root.serverController,
                updater: root.updater,
                openSettings: root.openSettings
            )
        )
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        // Leaving the panel closes it, as with a menu: another window or app took focus.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.lastResignClose = Date()
                self.close()
            }
        }
        return panel
    }

    /// A rounded rectangle that stretches, so the visual effect view is clipped to a native menu's corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A borderless panel that can take key status, so the switches and rows react as in a window.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { MenuBarController.shared.close() }
    }
}

/// Reads the on/off preference itself, so the panel redraws when it changes.
private struct MenuPanelRoot: View {
    let serverController: ServerController
    let updater: SPUUpdater
    let openSettings: () -> Void
    @AppStorage("isEnabled") private var isEnabled = true

    var body: some View {
        ContentView(
            serverManager: serverController,
            isEnabled: $isEnabled,
            updater: updater,
            openSettings: openSettings
        )
    }
}
