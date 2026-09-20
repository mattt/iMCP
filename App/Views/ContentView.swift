import AppKit
import Sparkle
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Environment(\.openSettings) private var openSettings

    private let aboutWindowController: AboutWindowController
    private let updater: SPUUpdater
    @State private var menuPanel = MenuPanelController()

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    private var serviceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: serviceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    init(
        serverManager: ServerController,
        isEnabled: Binding<Bool>,
        updater: SPUUpdater
    ) {
        self.serverController = serverManager
        self._isEnabled = isEnabled
        self.aboutWindowController = AboutWindowController()
        self.updater = updater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Enable MCP Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $isEnabled)
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .opacity(isEnabled ? 1.0 : 0.4)
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
                        await serverController.updateServiceBindings(serviceBindings)
                    }
                }
            }
            // No animation: it desyncs this auto-sizing panel's frame from its content.

            VStack(alignment: .leading, spacing: 2) {
                Divider()

                MenuButton("Configure Claude Desktop", dismiss: menuPanel.dismiss) {
                    ClaudeDesktop.showConfigurationPanel()
                }

                MenuButton("Copy server command to clipboard", dismiss: menuPanel.dismiss) {
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

                MenuButton("Settings...", dismiss: menuPanel.dismiss) {
                    // openSettings() alone is unreliable for this accessory (LSUIElement) app.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }

                MenuButton("Check for Updates...", dismiss: menuPanel.dismiss) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                MenuButton("About iMCP", dismiss: menuPanel.dismiss) {
                    aboutWindowController.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }

                MenuButton("Quit", dismiss: menuPanel.dismiss) {
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
        .background(Material.thick)
        .background(MenuPanelWindowReader(controller: menuPanel))
    }
}

/// Dismisses and resizes the `MenuBarExtra` panel that shows ``ContentView``.
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

    func dismiss() {
        window?.orderOut(nil)
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

private struct MenuButton: View {
    @Environment(\.isEnabled) private var isEnabled

    private let title: String
    private let action: () -> Void
    private let dismiss: @MainActor () -> Void
    @State private var isHighlighted: Bool = false
    @State private var isPressed: Bool = false

    init<S>(
        _ title: S,
        dismiss: @escaping @MainActor () -> Void,
        action: @escaping () -> Void
    ) where S: StringProtocol {
        self.title = String(title)
        self.dismiss = dismiss
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.primary.opacity(isEnabled ? 1.0 : 0.4))
                .multilineTextAlignment(.leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)

            Spacer()
        }
        .contentShape(Rectangle())
        .allowsHitTesting(isEnabled)
        .onTapGesture {
            guard isEnabled else { return }

            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = true
                }

                try? await Task.sleep(for: .milliseconds(100))

                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = false
                }

                action()
                dismiss()
            }
        }
        .frame(height: 18)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isPressed
                        ? Color.accentColor
                        : isHighlighted ? Color.accentColor.opacity(0.7) : Color.clear
                )
        )
        .onHover { state in
            guard isEnabled else { return }
            isHighlighted = state
        }
        .onChange(of: isEnabled) { _, newValue in
            if !newValue {
                isHighlighted = false
                isPressed = false
            }
        }
    }
}
