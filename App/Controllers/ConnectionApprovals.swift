/// Limits on connection approval requests.
struct ApprovalPolicy: Equatable, Sendable {
    /// The most connections that can be accepted but not yet approved,
    /// including connections that haven't sent their initialize request.
    var maximumUnapprovedConnections = 10
    /// The most approval dialogs on screen at once.
    var maximumOpenDialogs = 3
    /// The most connections waiting for a decision, in open or queued dialogs.
    var maximumWaitingConnections = 8
    /// How long a request waits for a decision before iMCP denies it.
    var expiry: Duration = .seconds(120)
    /// How long iMCP denies requests with the same cooldown key after a denial.
    var denialCooldown: Duration = .seconds(30)

    static let `default` = ApprovalPolicy()
}

/// Whether the app accepts a new connection on its socket.
enum ConnectionAdmission: Equatable {
    case accept
    case reject(Reason)

    enum Reason: Equatable {
        /// The person turned off the MCP server in iMCP.
        case disabled
        /// Too many connections wait for approval.
        case tooManyUnapproved
    }

    /// Decides whether to accept a connection before reading anything from it.
    static func decide(
        isEnabled: Bool,
        unapprovedCount: Int,
        policy: ApprovalPolicy = .default
    ) -> Self {
        guard isEnabled else { return .reject(.disabled) }
        guard unapprovedCount < policy.maximumUnapprovedConnections else {
            return .reject(.tooManyUnapproved)
        }
        return .accept
    }
}

/// Approval requests that wait for a person's decision.
///
/// Requests with the same key share one dialog.
/// The queue shows at most ``ApprovalPolicy/maximumOpenDialogs`` dialogs
/// and holds the other requests until a dialog closes.
/// It refuses connections beyond ``ApprovalPolicy/maximumWaitingConnections``,
/// expires requests that wait longer than ``ApprovalPolicy/expiry``,
/// and refuses requests for a while after a denial,
/// so that a client can't open dialogs faster than a person can answer them.
struct ApprovalQueue<Request, Waiter> {
    typealias Instant = ContinuousClock.Instant

    struct Entry {
        let key: String
        let cooldownKey: String
        let request: Request
        let deadline: Instant
        fileprivate(set) var waiters: [(id: AnyHashable, waiter: Waiter)]
        fileprivate(set) var isShown: Bool
    }

    enum Admission: Equatable {
        /// Show a new dialog for the request.
        case show(deadline: Instant)
        /// The request joined a dialog for the same key.
        case coalesced
        /// The request waits until another dialog closes.
        case queued(deadline: Instant)
        /// Deny the request now.
        case rejected(Rejection)
    }

    enum Rejection: Equatable {
        case tooManyWaiting
        case coolingDown
    }

    /// The result of removing requests from the queue.
    struct Resolution {
        /// The requests that were removed, with their waiters.
        var removed: [Entry] = []
        /// Queued requests whose dialogs to show now.
        var promoted: [Entry] = []
    }

    let policy: ApprovalPolicy
    private(set) var entries: [Entry] = []
    private var cooldowns: [String: Instant] = [:]

    init(policy: ApprovalPolicy = .default) {
        self.policy = policy
    }

    /// The number of connections waiting for a decision.
    var waitingCount: Int {
        entries.reduce(0) { $0 + $1.waiters.count }
    }

    /// The number of dialogs on screen.
    var shownCount: Int {
        entries.count(where: \.isShown)
    }

    /// Adds a connection's request.
    ///
    /// - Parameters:
    ///   - key: Requests with the same key share a dialog and a decision.
    ///   - cooldownKey: A denial refuses later requests with this key for a while.
    ///   - id: Identifies the waiter for ``cancel(id:)``.
    mutating func enqueue(
        key: String,
        cooldownKey: String,
        request: Request,
        id: AnyHashable,
        waiter: Waiter,
        now: Instant
    ) -> Admission {
        if let until = cooldowns[cooldownKey] {
            if now < until {
                return .rejected(.coolingDown)
            }
            cooldowns.removeValue(forKey: cooldownKey)
        }

        guard waitingCount < policy.maximumWaitingConnections else {
            return .rejected(.tooManyWaiting)
        }

        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].waiters.append((id, waiter))
            return .coalesced
        }

        let deadline = now.advanced(by: policy.expiry)
        let isShown = shownCount < policy.maximumOpenDialogs
        entries.append(
            Entry(
                key: key,
                cooldownKey: cooldownKey,
                request: request,
                deadline: deadline,
                waiters: [(id, waiter)],
                isShown: isShown
            )
        )
        return isShown ? .show(deadline: deadline) : .queued(deadline: deadline)
    }

    /// Removes the request with `key` after a person decides it.
    ///
    /// A denial starts the cooldown for the request's cooldown key.
    mutating func resolve(key: String, approved: Bool, now: Instant) -> Resolution {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return Resolution()
        }
        let entry = entries.remove(at: index)
        if !approved {
            cooldowns[entry.cooldownKey] = now.advanced(by: policy.denialCooldown)
        }
        return Resolution(removed: [entry], promoted: promote())
    }

    /// Removes the requests whose deadlines have passed, as denials.
    mutating func expire(now: Instant) -> Resolution {
        let expired = entries.filter { $0.deadline <= now }
        guard !expired.isEmpty else { return Resolution() }
        entries.removeAll { $0.deadline <= now }
        for entry in expired {
            cooldowns[entry.cooldownKey] = now.advanced(by: policy.denialCooldown)
        }
        return Resolution(removed: expired, promoted: promote())
    }

    /// Removes the waiter with `id`, for example because its connection closed.
    ///
    /// - Returns: The waiter, if it was waiting,
    ///   and the request it leaves without waiters, which is removed.
    mutating func cancel(id: AnyHashable) -> (waiter: Waiter?, resolution: Resolution) {
        guard let index = entries.firstIndex(where: { $0.waiters.contains { $0.id == id } }) else {
            return (nil, Resolution())
        }
        let waiterIndex = entries[index].waiters.firstIndex { $0.id == id }!
        let waiter = entries[index].waiters.remove(at: waiterIndex).waiter
        guard entries[index].waiters.isEmpty else {
            return (waiter, Resolution())
        }
        let entry = entries.remove(at: index)
        return (waiter, Resolution(removed: [entry], promoted: promote()))
    }

    /// Shows queued requests, oldest first, while there's room.
    private mutating func promote() -> [Entry] {
        var promoted: [Entry] = []
        for index in entries.indices where !entries[index].isShown {
            guard shownCount < policy.maximumOpenDialogs else { break }
            entries[index].isShown = true
            promoted.append(entries[index])
        }
        return promoted
    }
}
