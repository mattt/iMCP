import Foundation

/// What a person is asked to approve before iMCP does something that reaches another person,
/// such as sending a message or an email, or placing a call.
///
/// The "Allow writes" setting lets a client use a service's write tools at all.
/// An outbound action needs this approval as well, every time:
/// there is no "always allow", so one approval never covers a second send.
///
/// The client name and every detail come from outside iMCP,
/// so each is shown on one line and shortened:
/// a client or a group chat's name can't add lines that look like the recipient.
/// The body is shown as it will be sent.
struct OutboundConfirmationRequest: Equatable, Sendable {
    /// What is about to happen, as the window's title and button: "Send Message".
    let action: String
    /// The name that the MCP client gave when it connected, if known.
    let clientName: String?
    /// Labeled lines such as "To" and "Service", in the order shown.
    let details: [Detail]
    /// The full text that goes out, exactly as it will go out.
    let body: String?

    struct Detail: Equatable, Sendable {
        let label: String
        let value: String
        /// Whether to show `value` in a monospaced font, as for an identifier.
        let isIdentifier: Bool

        init(label: String, value: String, isIdentifier: Bool = false, maxLength: Int = 600) {
            self.label = OutboundConfirmationRequest.sanitized(label, maxLength: 40)
            self.value = OutboundConfirmationRequest.sanitized(value, maxLength: maxLength)
            self.isIdentifier = isIdentifier
        }
    }

    init(action: String, clientName: String?, details: [Detail], body: String? = nil) {
        self.action = Self.sanitized(action, maxLength: 40)
        let clientName = clientName.map { Self.sanitized($0, maxLength: 60) }
        self.clientName = clientName?.isEmpty == false ? clientName : nil
        self.details = details
        self.body = body
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

/// How a request for approval ended.
enum OutboundConfirmationAnswer: Equatable, Sendable {
    case approved
    case declined
    case timedOut
    /// Another confirmation was on screen, so this one wasn't shown.
    case busy
}

/// Asks the person to approve an outbound action.
///
/// The Mac app shows a window; tests answer without one.
protocol OutboundConfirming: Sendable {
    func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer
}

extension OutboundConfirming {
    /// Runs `perform` only if the person approves, and throws `OutboundConfirmationError` otherwise.
    ///
    /// Call it as the last step before the action, after anything that could fail on its own,
    /// so that the person is never asked about something that can't happen.
    func approve<T>(
        _ request: OutboundConfirmationRequest,
        then perform: () async throws -> T
    ) async throws -> T {
        switch await confirm(request) {
        case .approved:
            return try await perform()
        case .declined:
            throw OutboundConfirmationError.declined(action: request.action)
        case .timedOut:
            throw OutboundConfirmationError.timedOut(action: request.action)
        case .busy:
            throw OutboundConfirmationError.busy(action: request.action)
        }
    }
}

/// An outbound action that the person didn't approve. Nothing was done.
enum OutboundConfirmationError: LocalizedError, CustomStringConvertible, Equatable {
    case declined(action: String)
    case timedOut(action: String)
    case busy(action: String)

    var errorDescription: String? {
        switch self {
        case .declined(let action):
            "The user declined \"\(action)\" in iMCP. Nothing was done."
        case .timedOut(let action):
            "The confirmation for \"\(action)\" timed out after \(OutboundConfirmation.timeout.components.seconds) seconds. Nothing was done."
        case .busy(let action):
            "Another confirmation is waiting in iMCP, and only one is shown at a time, so \"\(action)\" wasn't shown. Try again after the user answers it. Nothing was done."
        }
    }

    var description: String { errorDescription ?? "" }
}

enum OutboundConfirmation {
    /// How long the person has to answer, from when the window appears.
    static let timeout: Duration = .seconds(50)

    /// How long the approve button stays disabled after the window appears,
    /// so a click aimed at something else as it appears can't approve.
    static let approveDelay: Duration = .milliseconds(500)

    /// Waits for the person's answer.
    ///
    /// `present` receives an answer handler (`true` to approve)
    /// and returns a closure that dismisses the window.
    /// A timeout or task cancellation dismisses the window without approval.
    /// Only one confirmation is on screen at a time:
    /// while one is open, another returns `.busy` without being shown,
    /// so a new window can't appear under a click meant for the first.
    /// The timeout starts when the window appears.
    @MainActor
    static func ask(
        timeout: Duration = OutboundConfirmation.timeout,
        gate: Gate = .shared,
        present: @MainActor (@escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void
    ) async -> OutboundConfirmationAnswer {
        guard gate.enter() else { return .busy }
        defer { gate.leave() }
        let pending = Pending()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                MainActor.assumeIsolated {
                    pending.continuation = continuation
                    let dismiss = present { approved in
                        pending.finish(approved ? .approved : .declined)
                    }
                    guard pending.isWaiting else { return }
                    pending.dismiss = dismiss
                    pending.timeoutTask = Task { @MainActor in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        pending.finish(.timedOut)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.declined) }
        }
    }

    /// Allows one confirmation on screen at a time.
    ///
    /// A second request is rejected rather than queued:
    /// a queued request could wait for the open one and then for its own window,
    /// longer than MCP clients commonly wait for a reply,
    /// and its window could then ask the person to approve something
    /// that the client has already given up on.
    @MainActor
    final class Gate {
        nonisolated static let shared = Gate()

        private(set) var isOpen = false

        nonisolated init() {}

        /// Opens the gate, or returns `false` when a confirmation is already open.
        func enter() -> Bool {
            guard !isOpen else { return false }
            isOpen = true
            return true
        }

        func leave() {
            isOpen = false
        }
    }

    /// Tracks one confirmation and accepts only its first answer.
    @MainActor
    private final class Pending {
        var continuation: CheckedContinuation<OutboundConfirmationAnswer, Never>?
        var dismiss: (@MainActor () -> Void)?
        var timeoutTask: Task<Void, Never>?

        var isWaiting: Bool { continuation != nil }

        func finish(_ answer: OutboundConfirmationAnswer) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            dismiss?()
            dismiss = nil
            continuation.resume(returning: answer)
        }
    }
}
