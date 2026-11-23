import AppKit
import SwiftUI

/// The window that asks the person to approve an outbound action, such as sending a message.
///
/// See `OutboundConfirmationRequest`. Only one window is on screen at a time.
struct OutboundConfirmationView: View {
    let request: OutboundConfirmationRequest
    let onApprove: () -> Void
    let onDecline: () -> Void

    @State private var isApproveEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("\(request.action)?")
                .font(.title2)
                .fontWeight(.semibold)

            Group {
                if let clientName = request.clientName {
                    Text("\"\(clientName)\" wants to do this.")
                } else {
                    Text("An app connected to iMCP wants to do this.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Array(request.details.enumerated()), id: \.offset) { _, detail in
                    GridRow {
                        Text("\(detail.label):")
                            .foregroundColor(.secondary)
                        Text(detail.value)
                            .font(detail.isIdentifier ? .caption.monospaced() : .body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let body = request.body {
                ScrollView {
                    Text(body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 60, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(
                "Click \(request.action) to confirm within \(OutboundConfirmation.timeout.components.seconds) seconds. Otherwise, nothing happens."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Omit a shortcut for approving, so an accidental Return can't approve.
            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    onDecline()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(request.action) {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isApproveEnabled)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            try? await Task.sleep(for: OutboundConfirmation.approveDelay)
            isApproveEnabled = true
        }
    }
}

@MainActor
final class OutboundConfirmationWindowController: NSObject, NSWindowDelegate {
    static let shared = OutboundConfirmationWindowController()

    /// Confirmation windows by request.
    private var windows: [UUID: NSWindow] = [:]
    /// Handlers for unanswered confirmations.
    private var answerHandlers: [UUID: (Bool) -> Void] = [:]

    /// Shows a confirmation window.
    ///
    /// Calls `onAnswer` at most once: `true` to approve, `false` for Cancel or close.
    /// Returns a closure that closes the window without an answer.
    func show(
        _ request: OutboundConfirmationRequest,
        onAnswer: @escaping (Bool) -> Void
    ) -> () -> Void {
        let id = UUID()
        let view = OutboundConfirmationView(
            request: request,
            onApprove: { [weak self] in self?.answer(id, true) },
            onDecline: { [weak self] in self?.answer(id, false) }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = request.action
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.delegate = self

        windows[id] = window
        answerHandlers[id] = onAnswer

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        return { [weak self] in self?.close(id) }
    }

    private func answer(_ id: UUID, _ approved: Bool) {
        guard let handler = answerHandlers.removeValue(forKey: id) else { return }
        close(id)
        handler(approved)
    }

    private func close(_ id: UUID) {
        answerHandlers.removeValue(forKey: id)
        guard let window = windows.removeValue(forKey: id) else { return }
        window.delegate = nil
        window.close()
    }

    /// Treat closing a window with the title bar button as Cancel.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windows.first(where: { $0.value === window })?.key
        else { return }

        windows.removeValue(forKey: id)
        window.delegate = nil
        answerHandlers.removeValue(forKey: id)?(false)
    }
}

/// Asks in a window on the Mac.
struct MacOutboundConfirmer: OutboundConfirming {
    private let defaultsSuiteName: String?

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if ApprovalMode.current(defaults: defaults).skipsConfirmationPopups {
            return .approved
        }
        return await OutboundConfirmation.ask { onAnswer in
            OutboundConfirmationWindowController.shared.show(request, onAnswer: onAnswer)
        }
    }
}

#Preview {
    OutboundConfirmationView(
        request: OutboundConfirmationRequest(
            action: "Send Message",
            clientName: "Claude Desktop",
            details: [
                .init(label: "To", value: "+15551234567"),
                .init(label: "Service", value: "iMessage"),
            ],
            body: "Running ten minutes late. Save me a seat?"
        ),
        onApprove: { print("Approve") },
        onDecline: { print("Decline") }
    )
}
