import AppKit
import Foundation
import MimeFoundation
import OSLog
import SQLite3
import os

private let log = Logger.service("mail")
private let mailDirectoryURL = URL(
    fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? "/Users/\(NSUserName())"
).appendingPathComponent("Library/Mail")
private let mailDirectoryBookmarkKey = "me.mattt.iMCP.mailDirectoryBookmark"
private let envelopeIndexPath = "MailData/Envelope Index"
private let defaultLimit = 30
private let maximumLimit = 100
private let maximumMessageSize = 32 * 1024 * 1024

final class MailService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MailService()

    private let files = MailFiles()

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabase
            log.debug("Mail service activation status: \(isActivated)")
            return isActivated
        }
    }

    /// Asks for the Mail folder when the index is not readable yet.
    ///
    /// Activation reports failures in an alert and never throws.
    /// `mail_compose` needs no folder access,
    /// so a canceled or denied grant must leave the service on.
    func activate() async throws {
        if canAccessDatabase {
            log.debug("Using the Mail index with the current grant")
            return
        }

        log.debug("Opening folder picker for the Mail folder")
        guard let selectedURL = await showFolderPicker() else { return }

        do {
            try withSecurityScopedAccess(selectedURL) { url in
                _ = try MailDatabase(root: url)
                try storeBookmark(for: url)
            }
            log.debug("Granted access to the Mail folder")
        } catch {
            log.error("Mail folder access failed: \(error.localizedDescription)")
            await showAlert(
                title: "Mail reading is unavailable",
                message: error.localizedDescription + " Composition is still available."
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "mail_mailboxes_list",
            description:
                "List mailboxes in the local Mail index. Use each @id as the mailbox search filter. Account email is included when available. Requires folder access.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let mailboxes = try self.withDatabase { try $0.mailboxes() }

            log.debug("Successfully listed \(mailboxes.count) mailboxes")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "itemListElement": Value.array(mailboxes.map(\.value)),
            ]
        }

        Tool(
            name: "mail_messages_search",
            description:
                "Search local sender and subject metadata. Filters combine with AND; newest first. Does not search bodies or download messages. Sync status is unknown; empty results do not prove the server mailbox is empty.",
            inputSchema: .object(
                properties: [
                    "sender": .string(
                        description: "Sender address substring"
                    ),
                    "subject": .string(
                        description: "Subject substring"
                    ),
                    "mailbox": .string(
                        description:
                            "The numeric @id string from mail_mailboxes_list, for example \"12\". Do not use the url field."
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "isRead": .boolean(
                        description: "If true, fetch read messages; if false, unread; if omitted, fetch all"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit),
                        minimum: 1,
                        maximum: maximumLimit
                    ),
                    "offset": .integer(
                        description: "Number of matching messages to skip",
                        default: .int(0),
                        minimum: 0
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Mail",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting mail search with arguments: \(arguments)")

            var request = MailRecord.FetchRequest()
            request.sender = try self.argument("sender", in: arguments, as: \.stringValue)
            request.subject = try self.argument("subject", in: arguments, as: \.stringValue)
            if let mailbox = arguments["mailbox"], !mailbox.isNull {
                request.mailbox = try MailboxRecord.parseIdentifier(mailbox)
            }
            if let start = try self.argument("start", in: arguments, as: \.stringValue) {
                guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: start) else {
                    throw MailError.invalidArgument("start must be an ISO 8601 date")
                }
                request.startDate = Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            if let end = try self.argument("end", in: arguments, as: \.stringValue) {
                guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: end) else {
                    throw MailError.invalidArgument("end must be an ISO 8601 date")
                }
                request.endDate = Calendar.current.normalizedEndDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            request.isRead = try self.argument("isRead", in: arguments, as: \.boolValue)
            request.limit = try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            request.offset = try self.argument("offset", in: arguments, as: \.intValue) ?? 0

            return try self.withDatabase { try $0.search(request) }
        }

        Tool(
            name: "mail_messages_read",
            description:
                "Read local MIME content by a returned message identifier. HTML is returned as labeled data; remote content is never loaded.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message identifier from mail_messages_search"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Mail",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let id = try self.argument("id", in: arguments, as: \.stringValue),
                let identifier = MailRecord.Identifier(id)
            else {
                throw MailError.invalidArgument("id must be an identifier from mail_messages_search")
            }

            // Keep the folder grant, but release SQLite before scanning message files.
            return try self.withDatabase { database in
                let record = try database.record(for: identifier)
                database.close()
                let content = try self.files.read(record, version: database.versionURL)
                return content.value(for: identifier)
            }
        }

        Tool(
            name: "mail_compose",
            description: "Open a compose URL in the default email app. Does not save or send a message.",
            inputSchema: .object(
                properties: [
                    "to": .string(
                        description: "Comma-separated recipient addresses"
                    ),
                    "cc": .string(
                        description: "Comma-separated CC addresses"
                    ),
                    "bcc": .string(
                        description: "Comma-separated BCC addresses"
                    ),
                    "subject": .string(),
                    "body": .string(
                        description: "Plain-text body"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Compose Mail",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: true
            )
        ) { arguments in
            let composition = MailComposition(
                to: try self.argument("to", in: arguments, as: \.stringValue),
                cc: try self.argument("cc", in: arguments, as: \.stringValue),
                bcc: try self.argument("bcc", in: arguments, as: \.stringValue),
                subject: try self.argument("subject", in: arguments, as: \.stringValue),
                body: try self.argument("body", in: arguments, as: \.stringValue)
            )

            log.debug("Opening a compose URL in the default email app")
            try composition.open(using: NSWorkspace.shared.open)

            return [
                "@context": "https://schema.org",
                "@type": "CommunicateAction",
                "description": "Opened the compose URL in the default email app. No message was saved or sent by iMCP.",
            ]
        }
    }

    /// Returns an optional argument, or throws if it is present with the wrong type.
    private func argument<T>(
        _ name: String,
        in arguments: [String: Value],
        as transform: (Value) -> T?
    ) throws -> T? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let result = transform(value) else {
            throw MailError.invalidArgument("\(name) has the wrong type")
        }
        return result
    }

    // MARK: - Database Access

    private var canAccessDatabase: Bool {
        // Status checks must not join Mail's SQLite locking protocol.
        // Schema and journal checks belong to explicit read requests.
        do {
            let root = try resolveBookmarkURL() ?? mailDirectoryURL
            return try withSecurityScopedAccess(root) { root in
                let location = try MailDatabase.location(in: root)
                return FileManager.default.isReadableFile(atPath: location.index.path)
            }
        } catch {
            return false
        }
    }

    /// Opens the index in the bookmarked folder, or at the default path when nothing is bookmarked.
    private func withDatabase<T>(_ operation: (MailDatabase) throws -> T) throws -> T {
        let root = try resolveBookmarkURL() ?? mailDirectoryURL

        // The grant must stay open until the last read:
        // SQLite opens the write-ahead log lazily on the first statement.
        return try withSecurityScopedAccess(root) { root in
            let database = try MailDatabase(root: root)
            defer { database.close() }
            return try operation(database)
        }
    }

    /// Returns the bookmarked Mail folder, or nil when no bookmark is stored.
    private func resolveBookmarkURL() throws -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: mailDirectoryBookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                log.debug("Renewing the stale Mail folder bookmark")
                try withSecurityScopedAccess(url, storeBookmark)
            }
            return url
        } catch {
            log.error("Failed to resolve the Mail folder bookmark: \(error.localizedDescription)")
            throw MailError.accessExpired
        }
    }

    /// Runs an operation inside the security scope of a URL.
    /// URLs without a scope, such as the default path, run the operation as they are.
    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) rethrows -> T {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: mailDirectoryBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    // MARK: - UI

    /// Returns the selected Mail folder, or nil when the user dismisses the panel.
    @MainActor
    private func showFolderPicker() -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message =
            "Select ~/Library/Mail to read local mail. If access is canceled or denied, composition stays available."
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = mailDirectoryURL.deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isMailDirectory(url) else {
            showAlert(
                title: "Select ~/Library/Mail to enable reading",
                message: "Other folders and exported mail are unsupported. Composition remains available."
            )
            return nil
        }

        return url
    }

    @MainActor
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func isMailDirectory(_ url: URL) -> Bool {
        return url.resolvingSymlinksInPath().path == mailDirectoryURL.resolvingSymlinksInPath().path
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Mail folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        return isMailDirectory(url)
    }
}

// MARK: -

enum MailError: LocalizedError, Equatable {
    case invalidArgument(String)

    case accessExpired
    case folderNotReadable
    case indexNotFound
    case indexNotReadable
    case unsupportedSchema
    case unsupportedJournalMode
    case databaseBusy
    case queryTimedOut
    case queryFailed(String)
    /// A file resolved to a location outside the folder that has to contain it.
    case notContained(String)

    case storeChanged
    case messageNotFound
    case messageFileNotFound
    case messageFileTooLarge
    case messageMismatch
    case unsupportedMailbox

    case partialMessage
    case encryptedMessage
    case malformedMessage(String)
    case unsupportedMessage(String)

    case composeFailed

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .accessExpired:
            return "Mail folder access has expired. Switch Mail off and on to select the folder again."
        case .folderNotReadable:
            return
                "Mail folder access is unavailable. Switch Mail off and on to select ~/Library/Mail. Composition remains available."
        case .indexNotFound:
            return
                "Mail access is unavailable: no local Envelope Index was found. Switch Mail off and on to select ~/Library/Mail."
        case .indexNotReadable:
            return
                "Mail access is unavailable. The index and its live WAL files must be readable. Switch Mail off and on to retry folder access."
        case .unsupportedSchema:
            return "Unsupported Mail Envelope Index schema."
        case .unsupportedJournalMode:
            return
                "Mail reading is unavailable because the index is not in WAL mode. iMCP will not change Mail's database settings."
        case .databaseBusy:
            return
                "Mail reading is busy. Try again later; iMCP does not wait for database locks or queue concurrent reads."
        case .queryTimedOut:
            return
                "Mail reading stopped to limit interference with Mail. Use a narrower date range or more specific filters."
        case .queryFailed(let message):
            return "Could not read the live Mail index: \(message)"
        case .notContained(let item):
            return "\(item) is outside the selected Mail folder."
        case .storeChanged:
            return "The Mail store changed. Search again for a current identifier."
        case .messageNotFound:
            return "Message is no longer in the local Mail index."
        case .messageFileNotFound:
            return "Local message file is missing or ambiguous. Open the message in Mail to download it."
        case .messageFileTooLarge:
            return "Local message exceeds the 32 MiB read limit or is not a regular file."
        case .messageMismatch:
            return "Local message identity does not match the Mail index."
        case .unsupportedMailbox:
            return "Unsupported mailbox storage mapping. Metadata search and composition remain available."
        case .partialMessage:
            return "Partial message: Mail has not downloaded all content."
        case .encryptedMessage:
            return "Encrypted message content is unavailable."
        case .malformedMessage(let reason):
            return "Malformed message: \(reason)."
        case .unsupportedMessage(let reason):
            return "Unsupported message: \(reason)."
        case .composeFailed:
            return "The default email app could not open the compose URL."
        }
    }
}

// MARK: -

/// A read-only connection to the Envelope Index of the newest Mail store in a folder.
/// The index is read live, without a copy and with its write-ahead log.
final class MailDatabase {
    // Overlapping readers can prevent WAL checkpoints from completing.
    // Only hold this lock to reserve/release a connection, never during SQLite work.
    private static let admission = OSAllocatedUnfairLock(initialState: false)

    /// The versioned store directory, such as `~/Library/Mail/V10`.
    let versionURL: URL
    private var connection: OpaquePointer?
    private var hasAdmission = false
    private let queryTimeLimit: Duration

    /// Finds the index without opening a SQLite connection.
    static func location(in root: URL) throws -> (version: URL, index: URL) {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            throw MailError.folderNotReadable
        }

        let versions: [(number: Int, url: URL)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.first == "V", let number = Int(name.dropFirst()),
                FileManager.default.fileExists(atPath: url.appendingPathComponent(envelopeIndexPath).path)
            else { return nil }
            return (number, url)
        }
        guard let version = versions.max(by: { $0.number < $1.number })?.url else {
            throw MailError.indexNotFound
        }

        let versionURL = version.resolvingSymlinksInPath()
        guard versionURL.isContained(in: root) else {
            throw MailError.notContained("The Mail store")
        }
        let databaseURL = version.appendingPathComponent(envelopeIndexPath).resolvingSymlinksInPath()
        guard databaseURL.isContained(in: versionURL) else {
            throw MailError.notContained("The Mail index")
        }
        return (versionURL, databaseURL)
    }

    init(root: URL, queryTimeLimit: Duration = .milliseconds(100)) throws {
        let location = try Self.location(in: root)
        versionURL = location.version
        self.queryTimeLimit = queryTimeLimit
        try Task.checkCancellation()

        hasAdmission = Self.admission.withLock { occupied in
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard hasAdmission else { throw MailError.databaseBusy }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        guard sqlite3_open_v2(location.index.path, &connection, flags, nil) == SQLITE_OK else {
            log.error("Failed to open the Mail index: \(String(cString: sqlite3_errmsg(self.connection)))")
            close()
            throw MailError.indexNotReadable
        }
        // Yield immediately to Mail rather than waiting or retrying.
        sqlite3_busy_timeout(connection, 0)

        do {
            // Rollback-journal readers can block commits. Refuse that mode;
            // never change the owner's journal settings or bypass its locks.
            guard try query("PRAGMA journal_mode", transform: { $0.text(0) }).first == "wal" else {
                throw MailError.unsupportedJournalMode
            }
            for (table, columns) in [
                "messages": ["ROWID", "mailbox", "subject", "sender", "date_received", "read", "message_id"],
                "mailboxes": ["ROWID", "url"],
                "subjects": ["ROWID", "subject"],
                "addresses": ["ROWID", "address"],
            ] {
                try query("SELECT \(columns.joined(separator: ", ")) FROM \(table) LIMIT 0") { _ in }
            }
        } catch {
            close()
            if case MailError.queryFailed = error {
                throw MailError.unsupportedSchema
            }
            throw error
        }
    }

    deinit {
        close()
    }

    /// Closes the connection. Call it before the security scope of the Mail folder ends.
    func close() {
        sqlite3_close(connection)
        connection = nil
        if hasAdmission {
            Self.admission.withLock { $0 = false }
            hasAdmission = false
        }
    }

    func mailboxes() throws -> [MailboxRecord] {
        let accounts = MailAccount.load(in: versionURL)
        return try query("SELECT ROWID, url FROM mailboxes ORDER BY url, ROWID") {
            try MailboxRecord($0, version: versionURL, accounts: accounts)
        }
    }

    func search(_ request: MailRecord.FetchRequest) throws -> Value {
        let records = try fetch(request)
        // Count the selected local scope without the search filters or pagination.
        let scope = MailRecord.FetchRequest(mailbox: request.mailbox)
        let (sql, bindings) = scope.statement(matchesLabels: try hasLabels, countOnly: true)
        let count = try query(sql, bindings) { $0.integer(0) ?? 0 }.first ?? 0
        return [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "itemListElement": .array(records.map(\.value)),
            "localIndex": [
                "indexedMessageCount": .int(Int(count)),
                "syncStatus": "unknown",
                "description": .string(
                    count == 0
                        ? "No messages are indexed locally in the selected scope. The mailbox may be empty or Mail may not have indexed it yet. Open Mail to check account sync."
                        : "The count covers locally indexed messages in the selected scope before search filters and pagination. Sync status and server message counts are unavailable."
                ),
            ],
        ]
    }

    func fetch(_ request: MailRecord.FetchRequest) throws -> [MailRecord] {
        try request.validate()
        if let mailbox = request.mailbox {
            let exists = try query("SELECT 1 FROM mailboxes WHERE ROWID = ?", [.integer(mailbox)]) { _ in true }
            guard !exists.isEmpty else {
                throw MailError.invalidArgument(
                    "mailbox does not exist in the local index. Use a current numeric @id string from mail_mailboxes_list, for example \"12\"; do not use the url field."
                )
            }
        }
        let (sql, bindings) = request.statement(matchesLabels: try hasLabels)
        return try query(sql, bindings) { try MailRecord($0, store: versionURL.lastPathComponent) }
    }

    /// Returns the indexed message that an identifier from an earlier fetch refers to.
    func record(for identifier: MailRecord.Identifier) throws -> MailRecord {
        guard identifier.store == versionURL.lastPathComponent else {
            throw MailError.storeChanged
        }
        guard let record = try fetch(.init(id: identifier.message)).first,
            record.mailbox == identifier.mailbox
        else {
            throw MailError.messageNotFound
        }
        return record
    }

    /// Whether the store has a usable `labels` table.
    /// Stores with that table record label membership of a message there.
    private var hasLabels: Bool {
        get throws {
            let tables = try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'labels'") {
                $0.text(0)
            }
            guard !tables.isEmpty else { return false }
            try query("SELECT message_id, mailbox_id FROM labels LIMIT 0") { _ in }
            return true
        }
    }

    /// Runs a statement and transforms each row of its result.
    @discardableResult
    func query<T>(
        _ sql: String,
        _ bindings: [Binding] = [],
        transform: (Row) throws -> T
    ) throws -> [T] {
        guard let connection else { throw MailError.indexNotReadable }
        let budget = QueryBudget(timeLimit: queryTimeLimit)
        try budget.check()
        sqlite3_progress_handler(
            connection,
            1000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue()
                return budget.shouldStop ? 1 : 0
            },
            Unmanaged.passUnretained(budget).toOpaque()
        )
        defer {
            sqlite3_progress_handler(connection, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try checkResult(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), budget: budget)

        for (offset, binding) in bindings.enumerated() {
            try checkResult(binding.bind(to: statement, at: Int32(offset + 1)), budget: budget)
        }

        var results: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try budget.check()
            results.append(try transform(Row(statement: statement)))
            try budget.check()
            result = sqlite3_step(statement)
        }
        try checkResult(result, budget: budget)
        return results
    }

    private func checkResult(_ result: Int32, budget: QueryBudget) throws {
        try budget.check()
        switch result & 0xff {
        case SQLITE_OK, SQLITE_DONE:
            return
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw MailError.databaseBusy
        default:
            throw MailError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    /// A cooperative deadline, including cancellation of the calling task.
    /// SQLite cannot call the progress handler while blocked in filesystem I/O.
    private final class QueryBudget {
        let deadline: ContinuousClock.Instant

        init(timeLimit: Duration) {
            deadline = ContinuousClock.now.advanced(by: timeLimit)
        }

        var shouldStop: Bool {
            Task.isCancelled || ContinuousClock.now >= deadline
        }

        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw MailError.queryTimedOut }
        }
    }
}

extension MailDatabase {
    /// A value bound to a `?` placeholder in a prepared statement.
    enum Binding {
        case text(String)
        case double(Double)
        case integer(Int64)

        fileprivate func bind(to statement: OpaquePointer?, at index: Int32) -> Int32 {
            switch self {
            case .text(let string):
                return sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .double(let double):
                return sqlite3_bind_double(statement, index, double)
            case .integer(let integer):
                return sqlite3_bind_int64(statement, index, integer)
            }
        }
    }

    /// The current row of a prepared statement. Accessors return nil for `NULL`.
    struct Row {
        fileprivate let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func integer(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        private func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Optional account labels stored inside the granted Mail folder.
struct MailAccount {
    let id: String
    let email: String?

    static func load(in version: URL) -> [String: MailAccount] {
        let url = version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
        guard url.isContained(in: version),
            let data = try? Data(contentsOf: url),
            let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }

        var accounts: [String: MailAccount] = [:]
        for (id, entry) in entries {
            guard let uuid = UUID(uuidString: id),
                let entry = entry as? [String: Any],
                let value = entry["AccountURL"] as? String,
                let components = URLComponents(string: value),
                let user = components.user, user.contains("@")
            else { continue }
            accounts[uuid.uuidString] = MailAccount(id: id, email: user)
        }
        return accounts
    }

    var value: Value {
        [
            "@id": .string(id),
            "email": email.map(Value.string) ?? .null,
        ]
    }
}

/// A row of the `mailboxes` table.
struct MailboxRecord {
    let id: Int64
    let url: String
    let account: MailAccount?

    var name: String {
        URL(string: url)?.lastPathComponent ?? url
    }

    static func parseIdentifier(_ value: Value) throws -> Int64 {
        guard let value = value.stringValue,
            !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
            let id = Int64(value), id > 0
        else {
            throw MailError.invalidArgument(
                "mailbox must be a positive numeric @id string from mail_mailboxes_list, for example \"12\"; do not use the url field."
            )
        }
        return id
    }

    fileprivate init(_ row: MailDatabase.Row, version: URL, accounts: [String: MailAccount]) throws {
        guard let id = row.integer(0) else {
            throw MailError.unsupportedSchema
        }
        self.id = id
        self.url = row.text(1) ?? ""
        let mailboxURL = URL(string: url)
        let accountID: String?
        if let mailboxURL, mailboxURL.isFileURL, mailboxURL.isContained(in: version) {
            accountID =
                mailboxURL.standardizedFileURL.pathComponents.dropFirst(
                    version.standardizedFileURL.pathComponents.count
                ).first
        } else {
            accountID = mailboxURL?.host
        }
        account = accountID.map {
            accounts[UUID(uuidString: $0)?.uuidString ?? $0] ?? MailAccount(id: $0, email: nil)
        }
    }

    /// The mailbox as a JSON object for tool output.
    var value: Value {
        [
            "@id": .string(String(id)),
            "@type": "Collection",
            "name": .string(name),
            "url": .string(url),
            "account": account?.value ?? .null,
        ]
    }
}

/// A row of the `messages` table, joined with its mailbox, subject, and sender.
struct MailRecord {
    /// The identifier that tools give out for a message.
    /// It names the store and mailbox as well,
    /// so an identifier from an earlier store or a moved message is rejected instead of misread.
    struct Identifier: Hashable, LosslessStringConvertible {
        let store: String
        let mailbox: Int64
        let message: Int64

        init(store: String, mailbox: Int64, message: Int64) {
            self.store = store
            self.mailbox = mailbox
            self.message = message
        }

        init?(_ description: String) {
            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty,
                let mailbox = Int64(parts[1]), mailbox > 0,
                let message = Int64(parts[2]), message > 0
            else { return nil }
            self.init(store: String(parts[0]), mailbox: mailbox, message: message)
        }

        var description: String {
            "\(store):\(mailbox):\(message)"
        }
    }

    let id: Int64
    let store: String
    let mailbox: Int64
    let mailboxURL: String
    let subject: String
    let sender: String
    let date: Date
    let isRead: Bool
    /// Some schemas store an integer here instead of the RFC Message-ID.
    let messageID: String

    var identifier: Identifier {
        Identifier(store: store, mailbox: mailbox, message: id)
    }

    /// Reads the current row of a statement prepared from `FetchRequest.statement(matchesLabels:)`.
    fileprivate init(_ row: MailDatabase.Row, store: String) throws {
        guard let id = row.integer(0), let mailbox = row.integer(1),
            let date = row.double(5), date.isFinite
        else {
            throw MailError.unsupportedSchema
        }

        self.id = id
        self.store = store
        self.mailbox = mailbox
        mailboxURL = row.text(2) ?? ""
        subject = row.text(3) ?? ""
        sender = row.text(4) ?? ""
        self.date = Date(timeIntervalSince1970: date)
        isRead = row.integer(6) == 1
        messageID = row.text(7) ?? ""
    }
}

extension MailRecord {
    struct FetchRequest {
        /// Sender address to match (partial, case-insensitive).
        var sender: String?
        /// Subject to match (partial, case-insensitive).
        var subject: String?
        /// Row identifier of a mailbox that holds the message or labels it.
        var mailbox: Int64?
        /// Start of the date range (inclusive).
        var startDate: Date?
        /// End of the date range (exclusive).
        var endDate: Date?
        var isRead: Bool?
        var limit = defaultLimit
        var offset = 0
        /// Row identifier of a single message.
        var id: Int64?

        fileprivate func validate() throws {
            guard (1 ... maximumLimit).contains(limit) else {
                throw MailError.invalidArgument("limit must be 1 through \(maximumLimit)")
            }
            guard offset >= 0 else {
                throw MailError.invalidArgument("offset must not be negative")
            }
            if let startDate, let endDate, startDate >= endDate {
                throw MailError.invalidArgument("start must be before end")
            }
        }

        /// The SQL and its bound values, in placeholder order.
        fileprivate func statement(matchesLabels: Bool, countOnly: Bool = false) -> (
            sql: String, bindings: [MailDatabase.Binding]
        ) {
            var conditions: [String] = []
            var bindings: [MailDatabase.Binding] = []

            // instr, unlike LIKE, has no wildcard characters to escape.
            if let sender {
                conditions.append("instr(lower(a.address), lower(?)) > 0")
                bindings.append(.text(sender))
            }
            if let subject {
                conditions.append("instr(lower(s.subject), lower(?)) > 0")
                bindings.append(.text(subject))
            }
            if let mailbox {
                if matchesLabels {
                    conditions.append(
                        """
                        (m.mailbox = ? OR EXISTS \
                        (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = ?))
                        """
                    )
                    bindings += [.integer(mailbox), .integer(mailbox)]
                } else {
                    conditions.append("m.mailbox = ?")
                    bindings.append(.integer(mailbox))
                }
            }
            if let startDate {
                conditions.append("m.date_received >= ?")
                bindings.append(.double(startDate.timeIntervalSince1970))
            }
            if let endDate {
                conditions.append("m.date_received < ?")
                bindings.append(.double(endDate.timeIntervalSince1970))
            }
            if let isRead {
                conditions.append("m.read = ?")
                bindings.append(.integer(isRead ? 1 : 0))
            }
            if let id {
                conditions.append("m.ROWID = ?")
                bindings.append(.integer(id))
            }
            if !countOnly {
                bindings += [.integer(Int64(limit)), .integer(Int64(offset))]
            }

            let whereClause =
                conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let columns =
                countOnly
                ? "COUNT(*)" : "m.ROWID, m.mailbox, b.url, s.subject, a.address, m.date_received, m.read, m.message_id"
            let pagination = countOnly ? "" : "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT ? OFFSET ?"
            let sql = """
                SELECT \(columns)
                FROM messages m
                JOIN mailboxes b ON b.ROWID = m.mailbox
                LEFT JOIN subjects s ON s.ROWID = m.subject
                LEFT JOIN addresses a ON a.ROWID = m.sender
                \(whereClause)
                \(pagination)
                """
            return (sql, bindings)
        }
    }

    /// The record as a JSON object for tool output.
    var value: Value {
        [
            "@type": "EmailMessage",
            "@id": .string(identifier.description),
            "mailbox": .string(String(mailbox)),
            "subject": .string(subject),
            "sender": [
                "@type": "Person",
                "email": .string(sender),
            ],
            "dateReceived": .string(date.formatted(.iso8601)),
            "isRead": .bool(isRead),
        ]
    }
}

// MARK: -

/// The readable content of a local `.emlx` message file.
struct MailContent {
    struct Header {
        let name: String
        let value: String
    }

    let headers: [Header]
    let body: String
    /// `text/plain`, or `text/html` for a message without a plain-text body.
    let mediaType: String
    let attachments: [String]
    let messageID: String?

    init(emlx data: Data) throws {
        let payload = try Self.payload(of: data)

        let message: MimeMessage
        do {
            message = try MimeMessage.load(MemoryStream(Array(payload), writable: false))
        } catch {
            throw MailError.malformedMessage(error.localizedDescription)
        }
        guard !message.headers.isEmpty else {
            throw MailError.malformedMessage("no MIME headers")
        }
        if let body = message.body {
            try Self.validate(body, in: payload)
        }

        let plain = message.textBody
        guard let body = plain ?? message.htmlBody else {
            throw MailError.unsupportedMessage("the local body is missing or not text")
        }

        headers = message.headers.map { Header(name: $0.field, value: $0.value) }
        self.body = body
        mediaType = plain != nil ? "text/plain" : "text/html"
        attachments = message.attachments.compactMap { ($0 as? MimePart)?.fileName }
        messageID = message.messageId
    }

    /// Returns the MIME payload of an `.emlx` file:
    /// the bytes that its first line counts, without the property list that follows them.
    private static func payload(of data: Data) throws -> Data {
        // Mail pads the byte count with spaces. The MIME payload still starts after
        // the original newline, not after the trimmed count.
        guard let newline = data.prefix(24).firstIndex(of: UInt8(ascii: "\n")),
            let line = String(data: data[..<newline], encoding: .ascii)
        else {
            throw MailError.malformedMessage("invalid .emlx byte-count prefix")
        }
        let prefix = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && $0.isNumber }),
            let length = Int(prefix), length > 0
        else {
            throw MailError.malformedMessage("invalid .emlx byte-count prefix")
        }

        let start = newline + 1
        guard length <= data.count - start else {
            throw MailError.partialMessage
        }
        let payload = data.subdata(in: start ..< (start + length))
        guard payload.range(of: Data("\r\n\r\n".utf8)) != nil || payload.range(of: Data("\n\n".utf8)) != nil else {
            throw MailError.malformedMessage("missing MIME header boundary")
        }
        return payload
    }

    /// Rejects content that the parser accepts but cannot return as complete text.
    private static func validate(_ entity: MimeEntity, in payload: Data, depth: Int = 0) throws {
        guard depth < 64 else {
            throw MailError.unsupportedMessage("MIME nesting is too deep")
        }

        switch entity.contentType.mimeType.lowercased() {
        case "multipart/encrypted", "application/pkcs7-mime", "application/x-pkcs7-mime",
            "application/pgp-encrypted":
            throw MailError.encryptedMessage
        case "message/partial":
            throw MailError.partialMessage
        default:
            break
        }

        if let text = entity as? TextPart, !text.isAttachment, let content = text.content {
            // The parser tolerates damaged transfer encodings. Do not report those as complete text.
            if text.contentTransferEncoding == .base64 {
                let encoded = MemoryStream()
                try content.writeTo(encoded)
                let whitespace = Set(" \t\r\n".utf8)
                let bytes = encoded.toByteArray().filter { !whitespace.contains($0) }
                guard Data(base64Encoded: Data(bytes)) != nil else {
                    throw MailError.malformedMessage("invalid base64 body")
                }
            }
            if text.contentType.charset != nil {
                guard let encoding = text.contentType.charsetEncoding else {
                    throw MailError.unsupportedMessage("unknown character encoding")
                }
                let decoded = MemoryStream()
                try content.decodeTo(decoded)
                guard String(data: Data(decoded.toByteArray()), encoding: encoding) != nil else {
                    throw MailError.malformedMessage("text does not match its character encoding")
                }
            }
        }

        if let multipart = entity as? Multipart {
            let ending = Data(("--" + multipart.boundary + "--").utf8)
            guard !multipart.isEmpty, payload.range(of: ending) != nil else {
                throw MailError.partialMessage
            }
            for child in multipart {
                try validate(child, in: payload, depth: depth + 1)
            }
        }
    }

    /// The content as a JSON object for tool output.
    func value(for identifier: MailRecord.Identifier) -> Value {
        [
            "@context": "https://schema.org",
            "@type": "EmailMessage",
            "@id": .string(identifier.description),
            "headers": .array(headers.map { ["name": .string($0.name), "value": .string($0.value)] }),
            "text": .string(body),
            "encodingFormat": .string(mediaType),
            "attachment": .array(attachments.map { ["@type": "MediaObject", "name": .string($0)] }),
        ]
    }
}

/// Finds and reads the `.emlx` files of indexed messages.
/// Cache entries are hints only. Every read checks containment and identity again.
final class MailFiles {
    private let cache = OSAllocatedUnfairLock(initialState: [MailRecord.Identifier: URL]())

    func read(_ record: MailRecord, version: URL) throws -> MailContent {
        let mailbox = try mailboxDirectory(record.mailboxURL, version: version)

        if let cached = cache.withLock({ $0[record.identifier] }) {
            do {
                return try load(cached, for: record, in: mailbox, version: version)
            } catch {
                cache.withLock { _ = $0.removeValue(forKey: record.identifier) }
            }
        }

        let url = try locate(record, in: mailbox)
        let content = try load(url, for: record, in: mailbox, version: version)
        cache.withLock {
            if $0.count >= 1000 { $0.removeAll() }
            $0[record.identifier] = url
        }
        return content
    }

    /// Maps the URL of a `mailboxes` row to its `.mbox` directory in the store.
    func mailboxDirectory(_ value: String, version: URL) throws -> URL {
        guard let url = URL(string: value) else {
            throw MailError.unsupportedMailbox
        }

        let directory: URL
        if url.isFileURL {
            directory = url
        } else if let host = url.host, UUID(uuidString: host) != nil {
            // Modern stores use the account UUID as the mailbox URL host.
            directory = try url.path.split(separator: "/").reduce(version.appendingPathComponent(host)) {
                guard $1 != ".", $1 != ".." else { throw MailError.unsupportedMailbox }
                return $0.appendingPathComponent("\($1).mbox")
            }
        } else {
            throw MailError.unsupportedMailbox
        }

        guard directory.pathExtension == "mbox" else {
            throw MailError.unsupportedMailbox
        }
        guard directory.isContained(in: version) else {
            throw MailError.notContained("The mailbox")
        }
        return directory.resolvingSymlinksInPath()
    }

    /// Searches a mailbox for the one file that holds a message.
    private func locate(_ record: MailRecord, in mailbox: URL) throws -> URL {
        guard
            let entries = FileManager.default.enumerator(
                at: mailbox,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw MailError.messageFileNotFound
        }

        var candidates: [URL] = []
        var isPartial = false
        for case let url as URL in entries {
            let isSymbolicLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            // Nested mailboxes have separate membership.
            if isSymbolicLink || url.pathExtension == "mbox" {
                entries.skipDescendants()
                continue
            }

            switch url.lastPathComponent {
            case "\(record.id).emlx":
                candidates.append(url)
            case "\(record.id).partial.emlx":
                isPartial = true
            default:
                break
            }
        }

        guard candidates.count == 1, let url = candidates.first else {
            throw isPartial ? MailError.partialMessage : MailError.messageFileNotFound
        }
        return url
    }

    private func load(_ url: URL, for record: MailRecord, in mailbox: URL, version: URL) throws -> MailContent {
        guard url.isContained(in: mailbox), url.isContained(in: version) else {
            throw MailError.notContained("The message file")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumMessageSize else {
            throw MailError.messageFileTooLarge
        }

        let content = try MailContent(emlx: Data(contentsOf: url))
        if record.messageID.contains("@") {
            let brackets = CharacterSet(charactersIn: "<>")
            guard
                content.messageID?.trimmingCharacters(in: brackets)
                    == record.messageID.trimmingCharacters(in: brackets)
            else {
                throw MailError.messageMismatch
            }
        }
        return content
    }
}

extension URL {
    /// Whether the file is inside a directory after both resolve their symbolic links.
    fileprivate func isContained(in directory: URL) -> Bool {
        resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }
}

// MARK: -

/// A draft that the default email app opens from a `mailto` URL.
struct MailComposition {
    /// Comma-separated recipient addresses.
    var to: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    /// Plain-text body. Line breaks of any kind become CRLF in the URL.
    var body: String?

    var url: URL {
        get throws {
            let forbidden = CharacterSet.controlCharacters.union(.newlines)
            for field in [to, cc, bcc, subject].compactMap({ $0 }) {
                guard !field.unicodeScalars.contains(where: forbidden.contains) else {
                    throw MailError.invalidArgument(
                        "recipients and subject must not contain line breaks or control characters"
                    )
                }
            }

            let body = body?
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            let fields = [("cc", cc), ("bcc", bcc), ("subject", subject), ("body", body)]
                .compactMap { name, value in value.map { name + "=" + Self.encode($0) } }
            let recipients = (to ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Self.encode(String($0)) }
                .joined(separator: ",")

            let query = fields.isEmpty ? "" : "?" + fields.joined(separator: "&")
            guard let url = URL(string: "mailto:" + recipients + query) else {
                throw MailError.composeFailed
            }
            return url
        }
    }

    /// Opens the draft. The opener returns whether an app accepted the URL.
    func open(using opener: (URL) -> Bool) throws {
        guard opener(try url) else {
            throw MailError.composeFailed
        }
    }

    /// Encodes everything but RFC 3986 unreserved characters,
    /// so no part of a field can act as a `mailto` delimiter.
    private static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
