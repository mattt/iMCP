import ExtensionFoundation
import FinanceKit
import OSLog

/// Receives Wallet changes in the background and queues them for the Mac.
///
/// The extension can't reach the Mac itself;
/// the app sends the queued changes the next time it runs.
@main
final class FinanceDelivery: BackgroundDeliveryExtension {
    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "finance")

    required init() {}

    func didReceiveData(for types: [FinanceStore.BackgroundDataType]) async {
        do {
            let outbox = try MobileOutbox.shared()
            try await FinanceSync.sync(into: outbox, generation: await outbox.generation)
        } catch {
            log.error("Queuing Wallet changes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func willTerminate() async {}
}
