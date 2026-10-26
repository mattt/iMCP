import AppKit
import SwiftUI

/// What the user sees before iMCP sends a message.
///
/// The client name, recipient, conversation ID, and service come from outside iMCP,
/// so they are shown on one line each and shortened:
/// a client or a group chat's name can't add lines that look like the To line.
/// The text is shown as it will be sent, in its own scrolling box.
struct MessageSendConfirmation: Equatable {
    /// The name that the MCP client gave when it connected, if known.
    let clientName: String?
    /// The phone number or email address,
    /// or the name and participants of a conversation.
    let recipient: String
    /// The conversation's ID, when the message goes to an existing conversation.
    let conversationID: String?
    let service: String
    /// The full text, exactly as it will be sent.
    let text: String

    init(clientName: String?, recipient: String, conversationID: String?, service: String, text: String) {
        let clientName = clientName.map { Self.sanitized($0, maxLength: 60) }
        self.clientName = clientName?.isEmpty == false ? clientName : nil
        self.recipient = Self.sanitized(recipient, maxLength: 600)
        self.conversationID = conversationID.map { Self.sanitized($0, maxLength: 200) }
        self.service = Self.sanitized(service, maxLength: 40)
        self.text = text
    }

    /// Returns `string` as one line of at most `maxLength` characters.
    ///
    /// Line breaks, tabs, and other whitespace become single spaces;
    /// other control characters and the Unicode bidirectional controls
    /// (embeddings, overrides, isolates, and marks) are removed,
    /// so the text can't reorder or reflow what is shown around it.
    /// A longer result ends with an ellipsis.
    static func sanitized(_ string: String, maxLength: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in string.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
            } else if properties.generalCategory == .control || properties.isBidiControl {
                continue
            } else {
                if pendingSpace {
                    scalars.append(" ")
                    pendingSpace = false
                }
                scalars.append(scalar)
            }
        }
        let line = String(scalars)
        guard line.count > maxLength else { return line }
        return line.prefix(max(maxLength - 1, 0)) + "…"
    }
}

struct MessageSendConfirmationView: View {
    /// How long Send stays disabled after the window appears,
    /// so a click aimed at something else as it appears can't send.
    static let sendDelay: Duration = .milliseconds(500)

    let confirmation: MessageSendConfirmation
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var isSendEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("Send Message?")
                .font(.title2)
                .fontWeight(.semibold)

            Group {
                if let clientName = confirmation.clientName, !clientName.isEmpty {
                    Text("\"\(clientName)\" wants to send this message.")
                } else {
                    Text("An app connected to iMCP wants to send this message.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("To:")
                        .foregroundColor(.secondary)
                    Text(confirmation.recipient)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let conversationID = confirmation.conversationID {
                    GridRow {
                        Text("Conversation:")
                            .foregroundColor(.secondary)
                        Text(conversationID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("Service:")
                        .foregroundColor(.secondary)
                    Text(confirmation.service)
                }
            }

            ScrollView {
                Text(confirmation.text)
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

            Text(
                "Click Send to confirm within \(MessageService.sendConfirmationTimeout.components.seconds) seconds. Otherwise, nothing is sent."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Omit a Send shortcut to prevent an accidental Return from sending.
            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Send") {
                    onSend()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isSendEnabled)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            try? await Task.sleep(for: Self.sendDelay)
            isSendEnabled = true
        }
    }
}

@MainActor
final class MessageSendConfirmationWindowController: NSObject, NSWindowDelegate {
    static let shared = MessageSendConfirmationWindowController()

    /// Whether windows are put on screen; tests build them without showing them.
    private let showsWindows: Bool
    /// Confirmation windows by request.
    /// `MessageService.askForConfirmation` shows one at a time.
    private var windows: [UUID: NSWindow] = [:]
    /// Handlers for unanswered confirmations.
    private var answerHandlers: [UUID: (Bool) -> Void] = [:]

    init(showsWindows: Bool = true) {
        self.showsWindows = showsWindows
    }

    /// The requests whose windows are open.
    var openConfirmationIDs: [UUID] { Array(windows.keys) }

    /// The window for a request, while it is open.
    func window(for id: UUID) -> NSWindow? { windows[id] }

    /// Shows a confirmation window for one message.
    ///
    /// Calls `onAnswer` at most once: `true` for Send, `false` for Cancel or close.
    /// Returns a closure to close the window without an answer.
    func show(
        _ confirmation: MessageSendConfirmation,
        onAnswer: @escaping (Bool) -> Void
    ) -> () -> Void {
        let id = UUID()
        let view = MessageSendConfirmationView(
            confirmation: confirmation,
            onSend: { [weak self] in self?.answer(id, true) },
            onCancel: { [weak self] in self?.answer(id, false) }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "Send Message"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.delegate = self

        windows[id] = window
        answerHandlers[id] = onAnswer

        if showsWindows {
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        return { [weak self] in self?.close(id) }
    }

    /// Answers a confirmation, as its Send and Cancel buttons do.
    /// Only the first answer counts.
    func answer(_ id: UUID, _ approved: Bool) {
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

#Preview {
    MessageSendConfirmationView(
        confirmation: MessageSendConfirmation(
            clientName: "Claude Desktop",
            recipient: "+15551234567",
            conversationID: nil,
            service: "iMessage",
            text: "Running ten minutes late. Save me a seat?"
        ),
        onSend: { print("Send") },
        onCancel: { print("Cancel") }
    )
}
