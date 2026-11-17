import AppKit
import SwiftUI

/// Asks the person to approve a client, laid out like a system alert:
/// the app's icon, a bold message, explanatory text, and the buttons below.
struct ConnectionApprovalView: View {
    let request: ClientCredentialStore.Request
    let enabledServiceNames: [String]
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    /// How long the Allow buttons stay off after the dialog appears.
    ///
    /// The dialog takes focus when it opens,
    /// so a click or a key press meant for another window could land on it.
    static let allowDelay: Duration = .seconds(1)

    @State private var canAllow = false

    private var app: ResponsibleApp? { request.app }

    /// The name to ask about.
    /// An app that iMCP can trust by signature is named by its signature,
    /// and any other client by the name it reported, which anyone can claim.
    private var displayName: String {
        request.offer == .signature ? (app?.name ?? request.claimedName) : request.claimedName
    }

    private var icon: NSImage {
        if let path = app?.bundlePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSApp.applicationIconImage
    }

    /// What iMCP verified, or didn't, about who is asking.
    private var identityText: String {
        if request.offer == .signature, let signer = app?.verifiedSigner {
            return "Verified: \(signer)."
        }
        if let app {
            return "Unverified name. It was started from \(app.name), which can run any program, "
                + "so iMCP can't tell this client from the others there."
        }
        return request.identityNote
    }

    private var servicesText: String {
        enabledServiceNames.isEmpty
            ? "No services are currently enabled."
            : "This gives the client access to \(enabledServiceNames.joined(separator: ", "))."
    }

    /// The title of the button that trusts the client, and what it does,
    /// or `nil` if the client can only be allowed once.
    private var trustButton: (title: String, note: String)? {
        switch request.offer {
        case .signature:
            ("Always Allow", "iMCP won't ask again for \(displayName), and it shows a notification when it connects.")
        case .credential:
            ("Always Allow", "This client connects without asking while it keeps its credential.")
        case nil:
            nil
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow “\(displayName)” to connect to iMCP?")
                        .font(.headline)

                    Text(identityText)
                    Text(servicesText)
                    if let note = trustButton?.note {
                        Text(note)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Deny") { onDeny() }
                    .keyboardShortcut(.cancelAction)

                // The Allow buttons have no keyboard shortcut, so that Return doesn't approve a connection.
                Button("Allow Once") { onApprove(false) }
                    .disabled(!canAllow)

                if let trustButton {
                    Button(trustButton.title) { onApprove(true) }
                        .disabled(!canAllow)
                }
            }
        }
        .task {
            guard (try? await Task.sleep(for: Self.allowDelay)) != nil else { return }
            canAllow = true
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = true
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
            wasTrustedByName: false,
            app: ResponsibleApp(
                name: "Claude",
                bundleIdentifier: "com.anthropic.claudefordesktop",
                bundlePath: "/Applications/Claude.app",
                teamIdentifier: "Q6L2SF6YDW",
                teamName: "Anthropic, PBC",
                requirement: "identifier \"com.anthropic.claudefordesktop\"",
                isAppleSigned: false,
                isAdHocSigned: false,
                code: nil
            )
        ),
        enabledServiceNames: ["Calendar", "Contacts", "Location"],
        onApprove: { alwaysTrust in
            print("Approved with always trust: \(alwaysTrust)")
        },
        onDeny: {
            print("Denied")
        }
    )
}
