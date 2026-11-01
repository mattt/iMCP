import AppKit
import SwiftUI

struct ConnectionApprovalView: View {
    let request: ClientCredentialStore.Request
    let enabledServiceNames: [String]
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    @State private var alwaysTrust = false

    private var clientName: String { request.claimedName }

    /// What selecting "Always trust this client" does.
    private var alwaysTrustNote: String {
        if request.record != nil {
            return "This client connects without asking while it keeps its credential."
        }
        return "iMCP creates a credential for you to add to the client's MCP settings."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Icon
            Image(.menuIconOn)
                .resizable()
                .foregroundColor(.accentColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            // Title
            Text("Client Connection Request")
                .font(.title2)
                .fontWeight(.semibold)

            // Message
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \"\(clientName)\" to connect to iMCP?")

                Text(request.identityNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if enabledServiceNames.isEmpty {
                    Text("No services are currently enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("This will give the client access to: \(enabledServiceNames.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Always trust checkbox
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Toggle("Always trust this client", isOn: $alwaysTrust)
                        .toggleStyle(CheckboxToggleStyle())
                    Spacer()
                }
                Text(alwaysTrustNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 20)

            // Buttons
            HStack(spacing: 12) {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onApprove(alwaysTrust)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .accentColor : .secondary)
                .accessibilityLabel(
                    configuration.isOn ? "Always trust this client, checked" : "Always trust this client, unchecked"
                )
                .onTapGesture {
                    configuration.isOn.toggle()
                }

            configuration.label
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

@MainActor
class ConnectionApprovalWindowController: NSObject, NSWindowDelegate {
    /// Open approval windows, keyed by approval key.
    /// Several clients can ask for approval at once,
    /// so each one gets its own window and its own close path.
    private var windows: [String: NSWindow] = [:]
    /// Deny handlers for windows the user closes with the title bar button
    /// instead of answering. Removed once a window has been answered.
    private var denyHandlers: [String: () -> Void] = [:]

    func showApprovalWindow(
        id: String,
        request: ClientCredentialStore.Request,
        enabledServiceNames: [String],
        onApprove: @escaping (Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        // Replace any stale window for the same key.
        closeWindow(for: id)

        // Create the SwiftUI view
        let approvalView = ConnectionApprovalView(
            request: request,
            enabledServiceNames: enabledServiceNames,
            onApprove: { [weak self] alwaysTrust in
                self?.denyHandlers.removeValue(forKey: id)
                onApprove(alwaysTrust)
                self?.closeWindow(for: id)
            },
            onDeny: { [weak self] in
                self?.denyHandlers.removeValue(forKey: id)
                onDeny()
                self?.closeWindow(for: id)
            }
        )

        // Create the hosting controller
        let hostingController = NSHostingController(rootView: approvalView)

        // Size the window to fit the view, which grows with its notes.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Connection Request"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = false
        window.delegate = self

        // Initial centering
        window.center()

        // Store references
        let cascadeIndex = windows.count
        windows[id] = window
        denyHandlers[id] = onDeny

        // Activate the app first
        NSApp.activate(ignoringOtherApps: true)

        // Show the window
        window.makeKeyAndOrderFront(nil)

        // Center again after showing to ensure proper positioning.
        // Offset each additional window so concurrent requests
        // do not hide each other.
        Task { @MainActor in
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let offset = CGFloat(cascadeIndex) * 24
                let x = (screenRect.width - windowRect.width) / 2 + screenRect.origin.x + offset
                let y = (screenRect.height - windowRect.height) / 2 + screenRect.origin.y - offset
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }

    func closeWindow(for id: String) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.delegate = nil
        window.close()
    }

    /// Treat closing a window with the title bar button as a denial,
    /// so the waiting connection is released instead of hanging forever.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windows.first(where: { $0.value === window })?.key
        else { return }

        windows.removeValue(forKey: id)
        window.delegate = nil
        denyHandlers.removeValue(forKey: id)?()
    }
}

#Preview {
    ConnectionApprovalView(
        request: .init(
            claimedName: "Claude Desktop",
            record: nil,
            hasUnrecognizedCredential: false,
            wasTrustedByName: true
        ),
        enabledServiceNames: ["Calendar", "Contacts", "Location"],
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
    .frame(width: 500, height: 400)
}
