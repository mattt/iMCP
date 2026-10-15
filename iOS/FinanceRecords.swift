import FinanceKit
import Foundation

// The app and its FinanceKit background delivery extension both compile this file,
// so it uses only Foundation, FinanceKit, and the shared outbox.

/// Whether this build and this device can read Wallet data.
enum FinanceCapability {
    case available
    case unavailable(String)

    static var current: FinanceCapability {
        // Apple grants the FinanceKit entitlement only after review,
        // so self-signed builds leave it out; see Scripts/install-ios.sh --finance.
        guard Bundle.main.object(forInfoDictionaryKey: "iMCPFinanceKit") as? String == "YES" else {
            return .unavailable(
                "This build of iMCP for iOS doesn't have the FinanceKit entitlement, which Apple grants only after review. Health and Alarms work without it."
            )
        }
        guard FinanceStore.isDataAvailable(.financialData) else {
            return .unavailable("Wallet financial data isn't available on this device or in this region.")
        }
        return .available
    }

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// JSON shapes for Wallet data, shared by live answers and the Mac's cache.
enum FinancePayload {
    struct Money: Codable, Equatable {
        var amount: String
        var currency: String
    }

    struct Account: Codable {
        var id: UUID
        var kind: String
        var displayName: String
        var description: String?
        var institutionName: String
        var currency: String
        var openingDate: Date?
        var creditLimit: Money?
        var nextPaymentDueDate: Date?
        var minimumNextPayment: Money?
        var overduePayment: Money?

        enum CodingKeys: String, CodingKey {
            case id, kind, description, currency
            case displayName = "display_name"
            case institutionName = "institution_name"
            case openingDate = "opening_date"
            case creditLimit = "credit_limit"
            case nextPaymentDueDate = "next_payment_due_date"
            case minimumNextPayment = "minimum_next_payment"
            case overduePayment = "overdue_payment"
        }
    }

    struct BalanceValue: Codable {
        var amount: String
        var currency: String
        var asOf: Date
        var creditDebit: String

        enum CodingKeys: String, CodingKey {
            case amount, currency
            case asOf = "as_of"
            case creditDebit = "credit_debit"
        }
    }

    struct Balance: Codable {
        var id: UUID
        var accountID: UUID
        var available: BalanceValue?
        var booked: BalanceValue?

        enum CodingKeys: String, CodingKey {
            case id, available, booked
            case accountID = "account_id"
        }

        var date: Date? { [available?.asOf, booked?.asOf].compactMap { $0 }.max() }
    }

    struct Transaction: Codable {
        var id: UUID
        var accountID: UUID
        var amount: String
        var currency: String
        var creditDebit: String
        var description: String
        var originalDescription: String
        var merchantName: String?
        var merchantCategoryCode: Int?
        var type: String
        var status: String
        var transactionDate: Date
        var postedDate: Date?
        var foreignAmount: Money?

        enum CodingKeys: String, CodingKey {
            case id, amount, currency, description, type, status
            case accountID = "account_id"
            case creditDebit = "credit_debit"
            case originalDescription = "original_description"
            case merchantName = "merchant_name"
            case merchantCategoryCode = "merchant_category_code"
            case transactionDate = "transaction_date"
            case postedDate = "posted_date"
            case foreignAmount = "foreign_amount"
        }
    }

    static func money(_ amount: CurrencyAmount?) -> Money? {
        amount.map { Money(amount: "\($0.amount)", currency: $0.currencyCode) }
    }

    static func account(_ account: FinanceKit.Account) -> Account {
        var payload = Account(
            id: account.id,
            kind: "asset",
            displayName: account.displayName,
            description: account.accountDescription,
            institutionName: account.institutionName,
            currency: account.currencyCode,
            openingDate: account.openingDate
        )
        if case .liability(let liability) = account {
            payload.kind = "liability"
            payload.creditLimit = money(liability.creditInformation.creditLimit)
            payload.nextPaymentDueDate = liability.creditInformation.nextPaymentDueDate
            payload.minimumNextPayment = money(liability.creditInformation.minimumNextPaymentAmount)
            payload.overduePayment = money(liability.creditInformation.overduePaymentAmount)
        }
        return payload
    }

    static func balance(_ balance: AccountBalance) -> Balance {
        func value(_ balance: FinanceKit.Balance?) -> BalanceValue? {
            balance.map {
                BalanceValue(
                    amount: "\($0.amount.amount)",
                    currency: $0.amount.currencyCode,
                    asOf: $0.asOfDate,
                    creditDebit: "\($0.creditDebitIndicator)"
                )
            }
        }
        return Balance(
            id: balance.id,
            accountID: balance.accountID,
            available: value(balance.available),
            booked: value(balance.booked)
        )
    }

    static func transaction(_ transaction: FinanceKit.Transaction) -> Transaction {
        Transaction(
            id: transaction.id,
            accountID: transaction.accountID,
            amount: "\(transaction.transactionAmount.amount)",
            currency: transaction.transactionAmount.currencyCode,
            creditDebit: "\(transaction.creditDebitIndicator)",
            description: transaction.transactionDescription,
            originalDescription: transaction.originalTransactionDescription,
            merchantName: transaction.merchantName,
            merchantCategoryCode: transaction.merchantCategoryCode.map { Int($0.rawValue) },
            type: "\(transaction.transactionType)",
            status: "\(transaction.status)",
            transactionDate: transaction.transactionDate,
            postedDate: transaction.postedDate,
            foreignAmount: money(transaction.foreignCurrencyAmount)
        )
    }

    static func record(_ account: FinanceKit.Account) throws -> MobileRecord {
        MobileRecord(
            kind: .account,
            id: account.id.uuidString,
            key: nil,
            start: account.openingDate,
            end: nil,
            payload: try MobileCoding.payload(self.account(account))
        )
    }

    static func record(_ balance: AccountBalance) throws -> MobileRecord {
        let payload = self.balance(balance)
        return MobileRecord(
            kind: .balance,
            id: balance.id.uuidString,
            key: balance.accountID.uuidString,
            start: payload.date,
            end: nil,
            payload: try MobileCoding.payload(payload)
        )
    }

    static func record(_ transaction: FinanceKit.Transaction) throws -> MobileRecord {
        MobileRecord(
            kind: .transaction,
            id: transaction.id.uuidString,
            key: transaction.accountID.uuidString,
            start: transaction.transactionDate,
            end: nil,
            payload: try MobileCoding.payload(self.transaction(transaction))
        )
    }
}

/// Queues Wallet changes for the Mac with FinanceKit history tokens,
/// so each sync sends only what changed since the last one.
enum FinanceSync {
    static var isEnabled: Bool { MobileAppGroup.defaults.bool(forKey: "service.finance") }

    static func sync(into outbox: MobileOutbox, generation: Int) async throws {
        guard isEnabled, case .available = FinanceCapability.current else { return }
        let store = FinanceStore.shared
        guard try await store.authorizationStatus() == .authorized else { return }

        try await drain(
            key: "finance.token.accounts",
            outbox: outbox,
            generation: generation,
            kind: .account,
            history: { store.accountHistory(since: $0, isMonitoring: false) },
            record: FinancePayload.record
        )
        let accounts = try await store.accounts(query: AccountQuery())
        for account in accounts {
            try await drain(
                key: "finance.token.balances.\(account.id)",
                outbox: outbox,
                generation: generation,
                kind: .balance,
                history: { store.accountBalanceHistory(forAccountID: account.id, since: $0, isMonitoring: false) },
                record: FinancePayload.record
            )
            try await drain(
                key: "finance.token.transactions.\(account.id)",
                outbox: outbox,
                generation: generation,
                kind: .transaction,
                history: { store.transactionHistory(forAccountID: account.id, since: $0, isMonitoring: false) },
                record: FinancePayload.record
            )
        }
        try await outbox.enqueue([], syncedAt: [.finance: Date()], generation: generation)
    }

    /// Reads one history from its saved token and queues each set of changes
    /// with the token that follows it.
    /// An expired token starts the history again from the beginning.
    private static func drain<Model: Identifiable>(
        key: String,
        outbox: MobileOutbox,
        generation: Int,
        kind: MobileKind,
        history: (FinanceStore.HistoryToken?) -> FinanceStore.History<Model>,
        record: (Model) throws -> MobileRecord
    ) async throws where Model.ID == UUID {
        var token = await outbox.state(key).flatMap {
            try? JSONDecoder().decode(FinanceStore.HistoryToken.self, from: $0)
        }
        do {
            try await read(history(token), key: key, outbox: outbox, generation: generation, kind: kind, record: record)
        } catch FinanceError.historyTokenInvalid {
            token = nil
            try await outbox.setState(key, nil, generation: generation)
            try await read(history(nil), key: key, outbox: outbox, generation: generation, kind: kind, record: record)
        }
    }

    private static func read<Model: Identifiable>(
        _ history: FinanceStore.History<Model>,
        key: String,
        outbox: MobileOutbox,
        generation: Int,
        kind: MobileKind,
        record: (Model) throws -> MobileRecord
    ) async throws where Model.ID == UUID {
        for try await changes in history {
            let records =
                try (changes.inserted + changes.updated).map(record)
                + changes.deleted.map { MobileRecord.deletion(kind: kind, id: $0.uuidString) }
            try await outbox.enqueue(
                records,
                syncedAt: [:],
                state: [key: try JSONEncoder().encode(changes.newToken)],
                generation: generation
            )
        }
    }
}
