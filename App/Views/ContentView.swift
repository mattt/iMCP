import AppKit
import Sparkle
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Environment(\.openSettings) private var openSettings

    private let updater: SPUUpdater
    @State private var menuPanel = MenuPanelController()

    private static let aboutCredits: NSAttributedString = {
        let credits = NSMutableAttributedString(
            string: "Report an Issue",
            attributes: [
                .link: URL(string: "https://github.com/mattt/iMCP/issues/new")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ]
        )
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        return credits
    }()

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    init(
        serverManager: ServerController,
        isEnabled: Binding<Bool>,
        updater: SPUUpdater
    ) {
        self.serverController = serverManager
        self._isEnabled = isEnabled
        self.updater = updater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Enable MCP Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Enable MCP Server", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.top, 2)
            .padding(.horizontal, 14)
            .onChange(of: isEnabled, initial: true) {
                Task {
                    await serverController.setEnabled(isEnabled)
                }
            }

            if isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    Text("Services")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 14)

                    ForEach(serviceConfigs) { config in
                        ServiceToggleView(config: config)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.horizontal, 2)
                .onChange(of: serviceConfigs.map { $0.binding.wrappedValue }, initial: true) {
                    Task {
                        await serverController.updateServiceBindings()
                    }
                }
            }
            // No animation: it desyncs this auto-sizing panel's frame from its content.

            VStack(alignment: .leading, spacing: 2) {
                Divider()

                MenuButton("Configure Claude Desktop") {
                    ClaudeDesktop.showConfigurationPanel(serverController: serverController)
                }

                MenuButton("Configure Claude Code") {
                    ClaudeCode.showConfigurationPanel(serverController: serverController)
                }

                MenuButton("Copy server command to clipboard") {
                    let command = Bundle.main.bundleURL
                        .appendingPathComponent("Contents/MacOS/imcp-server")
                        .path

                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(command, forType: .string)

                    _ = NSSound.play(.pop)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 2) {
                Divider()

                MenuButton("Settings...") {
                    // openSettings() alone is unreliable for this accessory (LSUIElement) app.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }

                MenuButton("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                MenuButton("About iMCP") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: Self.aboutCredits
                    ])
                }

                MenuButton("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.bottom, 2)
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            menuPanel.contentHeight = height
            menuPanel.resizeToFitContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MenuPanelWindowReader(controller: menuPanel))
    }
}

/// Resizes the `MenuBarExtra` panel that shows ``ContentView`` to fit its content.
@MainActor
final class MenuPanelController {
    var contentHeight: CGFloat = 0

    private weak var window: NSWindow?
    private var windowObserver: NSObjectProtocol?

    func attach(to newWindow: NSWindow?) {
        guard newWindow !== window else { return }

        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }

        window = newWindow
        guard let newWindow else { return }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizeToFitContent()
            }
        }
        resizeToFitContent()
    }

    // MenuBarExtra's window keeps a stale taller frame when its content shrinks,
    // leaving the content vertically centered in an oversized panel. Resize it to fit.
    func resizeToFitContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.contentHeight > 0 else { return }
            let frame = window.frame
            guard abs(frame.height - self.contentHeight) > 0.5 else { return }
            window.setFrame(
                NSRect(
                    x: frame.minX,
                    y: frame.maxY - self.contentHeight,
                    width: frame.width,
                    height: self.contentHeight
                ),
                display: true
            )
        }
    }
}

/// Gives ``MenuPanelController`` the window that contains this view.
private struct MenuPanelWindowReader: NSViewRepresentable {
    let controller: MenuPanelController

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(controller: controller)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}

    final class WindowReaderView: NSView {
        private let controller: MenuPanelController

        init(controller: MenuPanelController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.attach(to: window)
        }
    }
}

/// A row in the menu panel.
/// It's a real `Button`, so it works with the keyboard and VoiceOver,
/// and it highlights under the pointer like a menu item.
private struct MenuButton: View {
    private let title: String
    private let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    init<S>(
        _ title: S,
        action: @escaping () -> Void
    ) where S: StringProtocol {
        self.title = String(title)
        self.action = action
    }

    var body: some View {
        Button {
            action()

            // Hiding the panel window directly leaves the status item presented,
            // so the next click on it does nothing.
            dismiss()
        } label: {
            HStack {
                Text(title)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint.opacity(configuration.isPressed ? 1 : isHovering ? 0.7 : 0))
            )
            .onHover { isHovering = isEnabled && $0 }
    }
}
