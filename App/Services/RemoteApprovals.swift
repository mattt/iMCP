import Foundation

/// Offers the Mac's approvals to a paired iPhone or iPad, and applies the phone's answers.
///
/// Every approval still shows on the Mac. The first answer, from either device, wins:
/// the Mac withdraws the request from the phone when it answers first,
/// and the Mac closes its window when the phone answers first.
@MainActor
final class RemoteApprovals {
    static let shared = RemoteApprovals()

    /// The "Approve on iPhone" setting. It's on unless the person turns it off.
    static let defaultsKey = "approveOnIPhone"
    private static let interval: Duration = .seconds(1)

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private let broker: ApprovalBroker
    private var acknowledgements = Set<String>()
    private var loop: Task<Void, Never>?

    private init() {
        broker = ApprovalBroker(isPaired: { MobileService.shared.isPaired($0) })
    }

    /// Shows `request` on the paired phone, if "Approve on iPhone" is on and a phone is paired.
    /// `onResolved` runs on the main actor if the phone answers or the request expires there first.
    func offer(
        _ request: RemoteApprovalRequest,
        onResolved: @escaping @MainActor (RemoteApprovalOutcome) -> Void
    ) {
        guard Self.isEnabled, MobileService.shared.hasPairedDevice else { return }
        broker.open(request) { outcome in
            Task { @MainActor in onResolved(outcome) }
        }
        startLoop()
    }

    /// Removes `id` from the phone after the Mac answered or closed it.
    func withdraw(_ id: String) {
        guard broker.withdraw(id) else { return }
        startLoop()
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.tick()
                if !self.broker.hasPending && self.acknowledgements.isEmpty { break }
                try? await Task.sleep(for: Self.interval)
            }
            self?.loop = nil
        }
    }

    private func tick() async {
        let pending = broker.pending()
        let ack = acknowledgements
        guard let (device, answers) = await MobileService.shared.syncApprovals(pending: pending, ack: Array(ack))
        else {
            // Nothing is connected, so there is nothing to clear; open requests expire on their own.
            acknowledgements.subtract(ack)
            return
        }
        acknowledgements.subtract(ack)
        for answer in answers {
            _ = broker.receive(answer, from: device)
            acknowledgements.insert(answer.id)
        }
    }
}
