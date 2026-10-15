import FinanceKit
import Foundation

/// Reads Apple Card, Apple Cash, and Apple Savings data from Wallet with FinanceKit.
///
/// The code ships in every build but stays inactive
/// until a build carries the FinanceKit entitlement,
/// which Apple grants only after review.
/// Without it, the Finance tools report that they're unavailable and why.
struct FinancePhoneService: PhoneService {
    let domain = MobileDomain.finance

    private var store: FinanceStore { .shared }

    // MARK: - Tools

    func call(_ tool: String, _ args: MobileArguments) async throws -> Value {
        try await requireAccess()
        let results: [Value]
        switch tool {
        case "finance_accounts_list":
            results = try await store.accounts(query: AccountQuery()).map { try Self.value(FinancePayload.account($0)) }
        case "finance_balances_fetch":
            let account = try args.uuid("account")
            let start = try args.date("start") ?? .distantPast
            let end = try args.date("end") ?? .distantFuture
            let balances = try await store.accountBalances(query: AccountBalanceQuery())
                .map(FinancePayload.balance)
                .filter { balance in
                    guard account == nil || balance.accountID == account, let date = balance.date else { return false }
                    return date >= start && date <= end
                }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            results = try balances.prefix(args.limit()).map(Self.value)
        case "finance_transactions_fetch":
            let account = try args.uuid("account")
            let start = try args.date("start") ?? .distantPast
            let end = try args.date("end") ?? .distantFuture
            let status = args.string("status")
            let query = args.string("query")?.lowercased()
            let limit = args.limit()
            let filtered = account != nil || status != nil || query != nil
            let transactions = try await store.transactions(
                query: TransactionQuery(
                    sortDescriptors: [SortDescriptor(\.transactionDate, order: .reverse)],
                    predicate: #Predicate { $0.transactionDate >= start && $0.transactionDate <= end },
                    limit: filtered ? nil : limit
                )
            )
            let matches = transactions.map(FinancePayload.transaction).filter { transaction in
                if let account, transaction.accountID != account { return false }
                if let status, transaction.status != status { return false }
                if let query {
                    let text = [transaction.merchantName, transaction.description].compactMap { $0?.lowercased() }
                    if !text.contains(where: { $0.contains(query) }) { return false }
                }
                return true
            }
            results = try matches.prefix(limit).map(Self.value)
        default:
            throw MobileError("Unknown Finance tool: \(tool)")
        }
        return MobileEnvelope.make(domain: .finance, source: .live, syncedAt: Date(), results: results)
    }

    private func requireAccess() async throws {
        if let reason = FinanceCapability.current.reason { throw MobileError(reason) }
        switch try await store.authorizationStatus() {
        case .authorized: return
        case .denied:
            throw MobileError(
                "Wallet access is off for iMCP. Turn it on in Settings > Apps > iMCP."
            )
        default:
            throw MobileError("Open iMCP on the iPhone or iPad and turn on Finance to allow Wallet access.")
        }
    }

    private static func value<T: Encodable>(_ payload: T) throws -> Value {
        try JSONDecoder().decode(Value.self, from: MobileCoding.payload(payload))
    }

    // MARK: - PhoneService

    func status() async -> Value {
        if let reason = FinanceCapability.current.reason {
            return ["available": false, "note": .string(reason)]
        }
        let status: String
        switch try? await store.authorizationStatus() {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .notDetermined: status = "notDetermined"
        default: status = "unknown"
        }
        return ["available": true, "authorization": .string(status)]
    }

    func requestAuthorization() async throws {
        if let reason = FinanceCapability.current.reason { throw MobileError(reason) }
        guard try await store.requestAuthorization() == .authorized else {
            throw MobileError("Allow Wallet access for iMCP to turn on Finance.")
        }
    }

    func sync(into outbox: MobileOutbox, generation: Int) async throws {
        try await FinanceSync.sync(into: outbox, generation: generation)
    }

    func startBackgroundDelivery() async {
        guard case .available = FinanceCapability.current else { return }
        // The extension in MobileFinance receives the changes and queues them for the Mac.
        store.enableBackgroundDelivery(for: [.accounts, .accountBalances, .transactions], frequency: .hourly)
    }

    func stopBackgroundDelivery() async {
        guard case .available = FinanceCapability.current else { return }
        store.disableAllBackgroundDelivery()
    }
}
