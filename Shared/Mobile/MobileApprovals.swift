import Foundation

// Approvals that the Mac can send to a paired iPhone or iPad.
// This file uses only Foundation, so the Mac app, the iOS app, and tests compile it.

/// What a person is asked to approve.
enum RemoteApprovalKind: String, Codable, Sendable {
    /// An MCP client asks to connect.
    case connection
    /// iMCP is about to send a message, an email, or a call.
    case send
    /// An app asks for public access through OAuth.
    case oauth
}

enum RemoteApprovalDecision: String, Codable, Sendable {
    case approve
    case deny
}

/// An approval that the Mac asks the phone to show.
///
/// `details` are labeled lines, such as "To: +1 555 0100".
/// `body` is the full text of a send, exactly as it will go out.
struct RemoteApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: RemoteApprovalKind
    var title: String
    var details: [String]
    var body: String?
    var expiresAt: Date

    init(id: String, kind: RemoteApprovalKind, title: String, details: [String], body: String? = nil, expiresAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.body = body
        self.expiresAt = expiresAt
    }
}

/// The phone's answer to one request.
struct RemoteApprovalAnswer: Codable, Equatable, Sendable {
    var id: String
    var decision: RemoteApprovalDecision
}

/// The Mac's call to the phone that carries approvals in both directions.
enum RemoteApprovalLink {
    /// Arguments: `pending`, the Mac's open requests, and `ack`, the IDs of answers it has handled.
    /// Result: `answers`, the phone's answers that the Mac hasn't acknowledged.
    static let syncTool = "approval_sync"
}

struct RemoteApprovalSyncRequest: Codable, Equatable, Sendable {
    var pending: [RemoteApprovalRequest]
    var ack: [String]
}

struct RemoteApprovalSyncResponse: Codable, Equatable, Sendable {
    var answers: [RemoteApprovalAnswer]
}

// MARK: - Mac

/// How an approval on the Mac ended when the phone, or the clock, decided it.
enum RemoteApprovalOutcome: Equatable, Sendable {
    case approved
    case denied
    /// The request expired. It counts as a denial.
    case expired

    var isApproved: Bool { self == .approved }
}

/// What the Mac did with an answer from a device.
enum RemoteApprovalReceipt: Equatable, Sendable {
    case accepted
    /// The answer came from a device that isn't paired.
    case unpairedDevice
    /// No open request has this ID: it was never sent, already answered, withdrawn, or expired.
    case unknownRequest
}

/// Tracks the approvals that the Mac has offered to a phone, and accepts one answer for each.
///
/// The first answer wins, whichever device gives it:
/// `resolveLocally` and `receive` both remove the request,
/// so a second answer finds nothing to answer.
/// An answer is bound to a request ID and works once.
/// It counts only from a paired device;
/// the channel's pre-shared key authenticates which device sent it.
/// A request that expires is resolved as a denial, and a late answer is rejected.
final class ApprovalBroker: @unchecked Sendable {
    private struct Entry {
        var request: RemoteApprovalRequest
        var onResolved: @Sendable (RemoteApprovalOutcome) -> Void
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let isPaired: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date

    init(
        isPaired: @escaping @Sendable (String) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isPaired = isPaired
        self.now = now
    }

    /// Offers `request` to the phone.
    /// `onResolved` runs once, if the phone answers or the request expires first.
    /// It doesn't run when the Mac answers or `withdraw` removes the request.
    func open(_ request: RemoteApprovalRequest, onResolved: @escaping @Sendable (RemoteApprovalOutcome) -> Void) {
        lock.withLock { entries[request.id] = Entry(request: request, onResolved: onResolved) }
    }

    /// The open requests that haven't expired.
    func pending() -> [RemoteApprovalRequest] {
        expireDue()
        return lock.withLock { entries.values.map(\.request).sorted { $0.expiresAt < $1.expiresAt } }
    }

    var hasPending: Bool { lock.withLock { !entries.isEmpty } }

    /// Applies an answer from `device`.
    func receive(_ answer: RemoteApprovalAnswer, from device: String) -> RemoteApprovalReceipt {
        guard isPaired(device) else { return .unpairedDevice }
        expireDue()
        guard let entry = lock.withLock({ entries.removeValue(forKey: answer.id) }) else {
            return .unknownRequest
        }
        entry.onResolved(answer.decision == .approve ? .approved : .denied)
        return .accepted
    }

    /// Removes a request that the Mac answered itself, so the phone's later answer is ignored.
    /// Returns whether the request was still open.
    @discardableResult
    func withdraw(_ id: String) -> Bool {
        lock.withLock { entries.removeValue(forKey: id) } != nil
    }

    /// Resolves requests whose time has passed as denials.
    func expireDue() {
        let date = now()
        let expired = lock.withLock {
            let due = entries.values.filter { $0.request.expiresAt <= date }
            for entry in due { entries.removeValue(forKey: entry.request.id) }
            return due
        }
        for entry in expired { entry.onResolved(.expired) }
    }
}

// MARK: - Phone

/// The approvals that the phone shows, and the answers it hasn't delivered.
///
/// It lives in memory only: a pending approval is worthless after the app restarts,
/// and nothing here holds a database lock while iOS suspends the app.
final class ApprovalInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: RemoteApprovalRequest] = [:]
    private var answers: [String: RemoteApprovalDecision] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    struct SyncResult: Equatable, Sendable {
        /// Requests that weren't open before this sync.
        var added: [RemoteApprovalRequest]
        /// IDs that the Mac no longer has open.
        var removed: [String]
        /// Answers the Mac hasn't acknowledged.
        var answers: [RemoteApprovalAnswer]
    }

    /// Replaces the open requests with the Mac's list and drops answers the Mac has handled.
    func sync(pending: [RemoteApprovalRequest], ack: [String]) -> SyncResult {
        lock.withLock {
            let incoming = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let added = pending.filter { requests[$0.id] == nil && answers[$0.id] == nil }
            let removed = requests.keys.filter { incoming[$0] == nil }
            requests = incoming
            for id in ack { answers.removeValue(forKey: id) }
            return SyncResult(added: added, removed: Array(removed), answers: undelivered())
        }
    }

    /// The requests to show: open, not expired, and not yet answered here.
    func visible() -> [RemoteApprovalRequest] {
        let date = now()
        return lock.withLock {
            requests.values
                .filter { answers[$0.id] == nil && $0.expiresAt > date }
                .sorted { $0.expiresAt < $1.expiresAt }
        }
    }

    /// Records the person's answer. The Mac gets it on its next sync.
    /// Returns false if the request is gone, expired, or already answered.
    @discardableResult
    func answer(_ id: String, _ decision: RemoteApprovalDecision) -> Bool {
        let date = now()
        return lock.withLock {
            guard let request = requests[id], request.expiresAt > date, answers[id] == nil else { return false }
            answers[id] = decision
            return true
        }
    }

    /// Records an answer for a request this phone may not have loaded yet,
    /// as when a notification button wakes the app before it reconnects.
    /// The Mac rejects an ID it doesn't have open.
    func answerFromNotification(_ id: String, _ decision: RemoteApprovalDecision) {
        lock.withLock { if answers[id] == nil { answers[id] = decision } }
    }

    /// Whether the Mac has acknowledged every answer given here.
    var hasUndeliveredAnswers: Bool { lock.withLock { !answers.isEmpty } }

    private func undelivered() -> [RemoteApprovalAnswer] {
        answers.map { RemoteApprovalAnswer(id: $0.key, decision: $0.value) }.sorted { $0.id < $1.id }
    }
}
