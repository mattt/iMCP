import AppKit
import OSLog
import Ontology
import SQLite3

private let log = Logger.service("phone")
private let callHistoryDirectoryPath =
    "/Users/\(NSUserName())/Library/Application Support/CallHistoryDB"
private let callHistoryDatabaseName = "CallHistory.storedata"
private let callHistoryDatabasePath = callHistoryDirectoryPath + "/" + callHistoryDatabaseName
private let callHistoryDatabaseBookmarkKey: String = "me.mattt.iMCP.callHistoryDatabaseBookmark"
private let defaultLimit = 30

final class PhoneService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = PhoneService()

    var tools: [Tool] {
        Tool(
            name: "phone_calls_fetch",
            description: "Fetch phone call history from the Mac (synced from iPhone)",
            inputSchema: .object(
                properties: [
                    "participant": .string(
                        description:
                            "Phone number or contact name to filter by (partial match supported)"
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). ISO 8601 format. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). ISO 8601 format. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "call_type": .string(
                        description: "Filter by call type, or omit for all",
                        enum: ["incoming", "outgoing", "missed"]
                    ),
                    "limit": .integer(
                        description: "Maximum calls to return",
                        default: .int(defaultLimit),
                        minimum: 1
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Call History",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting call history fetch with arguments: \(arguments)")

            let limit = try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            guard limit >= 1 else {
                throw ArgumentError.invalid("limit must be a positive integer")
            }
            var request = CallRecord.FetchRequest(limit: limit)
            request.participant = try self.argument("participant", in: arguments, as: \.stringValue)
            if let callType = try self.argument("call_type", in: arguments, as: \.stringValue) {
                guard let type = CallRecord.CallType(rawValue: callType.lowercased()) else {
                    throw ArgumentError.invalid(
                        "call_type must be one of: incoming, outgoing, missed"
                    )
                }
                request.callType = type
            }
            if let start = try self.argument("start", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: start
                    )
                else {
                    throw ArgumentError.invalid("start must be an ISO 8601 date")
                }
                request.startDate = parsed.date
            }
            if let end = try self.argument("end", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: end
                    )
                else {
                    throw ArgumentError.invalid("end must be an ISO 8601 date")
                }
                request.endDate = parsed.date
            }

            try await self.requestDatabaseAccess()
            let calls = try self.withDatabase { try $0.fetch(request) }

            log.debug("Successfully fetched \(calls.count) calls")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Call History",
                "numberOfItems": .int(calls.count),
                "itemListElement": Value.array(calls.map(\.value)),
            ]
        }

        Tool(
            name: "phone_call",
            description:
                "Start a phone call from the Mac (via iPhone). The system asks the user to confirm before dialing.",
            inputSchema: .object(
                properties: [
                    "phoneNumber": .string(
                        description:
                            "Phone number to call. E.164 format is recommended. Digits, a leading +, and common formatting only; * and # are not supported."
                    )
                ],
                required: ["phoneNumber"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Call Phone Number",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: true
            )
        ) { arguments in
            guard let phoneNumber = arguments["phoneNumber"]?.stringValue,
                !phoneNumber.isEmpty
            else {
                throw CallError.missingPhoneNumber
            }

            // Accept only digits, a leading "+", and common formatting; reject anything else
            // rather than silently dialing a different number (e.g. "help911" -> "911").
            // The Phone app refuses tel: URLs containing "*" or "#", so those are rejected too.
            let digits = Set("0123456789")
            let dialable = digits.union("+")
            let formatting = Set(" -().")
            guard phoneNumber.allSatisfy({ dialable.contains($0) || formatting.contains($0) })
            else {
                throw CallError.invalidPhoneNumber(phoneNumber)
            }

            let dialString = phoneNumber.filter { !formatting.contains($0) }
            guard dialString.contains(where: digits.contains) else {
                throw CallError.invalidPhoneNumber(phoneNumber)
            }

            var components = URLComponents()
            components.scheme = "tel"
            components.path = dialString
            guard let url = components.url else {
                throw CallError.invalidPhoneNumber(phoneNumber)
            }

            log.debug("Requesting phone call to \(dialString)")
            guard NSWorkspace.shared.open(url) else {
                throw CallError.openFailed
            }

            return CommunicateAction(
                recipient: Person(telephone: dialString),
                status: .potential,
                description: "The system asked the user to confirm the call."
            )
        }
    }

    // MARK: - Database Access

    /// Ensures the call history database is readable, asking the user to grant access if needed.
    ///
    /// The grant has to cover the `CallHistoryDB` folder, not just the store file.
    /// The store is a WAL-mode SQLite database, so SQLite also opens the `-wal` and `-shm`
    /// files next to it. A bookmark on the file alone, as earlier versions stored,
    /// leaves those unreadable and every read fails with "authorization denied".
    private func requestDatabaseAccess() async throws {
        if canAccessDatabaseAtDefaultPath {
            log.debug("Using call history database at default path")
            return
        }

        switch try? resolveBookmarkedGrant() {
        case .directory where canAccessDatabaseUsingBookmark:
            log.debug("Using call history database from stored bookmark")
            return
        case .file:
            log.warning(
                "The stored grant covers \(callHistoryDatabaseName) alone and cannot reach its write-ahead log; asking for the CallHistoryDB folder instead"
            )
        default:
            break
        }

        log.debug("Opening folder picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFolderPicker()

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        try storeBookmark(for: selectedURL)
        log.debug("Granted access to call history database")
    }

    /// Returns an optional argument, or throws if it is present with the wrong type.
    private func argument<T>(
        _ name: String,
        in arguments: [String: Value],
        as transform: (Value) -> T?
    ) throws -> T? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let result = transform(value) else {
            throw ArgumentError.invalid("\(name) has the wrong type")
        }
        return result
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: callHistoryDatabasePath)
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let grant = try resolveBookmarkedGrant()
            return try withSecurityScopedAccess(grant.url) { _ in
                FileManager.default.isReadableFile(atPath: grant.databaseURL.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    /// What the stored bookmark grants access to.
    private enum BookmarkedGrant {
        /// The `CallHistoryDB` folder: the store together with its write-ahead log.
        case directory(URL)
        /// The store file alone, as stored by earlier versions.
        /// The log next to it is unreadable, so reads through this grant fail.
        case file(URL)

        var url: URL {
            switch self {
            case .directory(let url), .file(let url):
                return url
            }
        }

        var databaseURL: URL {
            switch self {
            case .directory(let url):
                return url.appendingPathComponent(callHistoryDatabaseName)
            case .file(let url):
                return url
            }
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent(callHistoryDatabaseName)
    }

    private func resolveBookmarkedGrant() throws -> BookmarkedGrant {
        let url = try resolveBookmarkURL()
        let isDirectory = try withSecurityScopedAccess(url) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
        }
        return isDirectory ? .directory(url) : .file(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard
            let bookmarkData = UserDefaults.standard.data(forKey: callHistoryDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func withDatabase<T>(_ operation: (CallHistoryDatabase) throws -> T) throws -> T {
        if canAccessDatabaseAtDefaultPath {
            return try read(at: callHistoryDatabasePath, operation)
        }

        let grant = try resolveBookmarkedGrant()
        guard case .directory = grant else {
            throw DatabaseAccessError.insufficientGrant
        }

        // The grant must stay open until the last read:
        // SQLite opens the write-ahead log lazily on the first statement.
        return try withSecurityScopedAccess(grant.url) { _ in
            try read(at: grant.databaseURL.path, operation)
        }
    }

    /// Reads the store live, honoring its write-ahead log.
    /// If SQLite cannot open the log's companion files, for example because they are absent
    /// and the folder is read-only, it reads the main file alone instead.
    /// Nothing is lost then: without a log, every record is already in the main file.
    private func read<T>(at path: String, _ operation: (CallHistoryDatabase) throws -> T) throws -> T {
        do {
            return try operation(CallHistoryDatabase(path: path, immutable: false))
        } catch let error as SQLiteError {
            log.warning(
                "Live read of the call history database failed (\(error.message)); retrying without its write-ahead log"
            )
            return try operation(CallHistoryDatabase(path: path, immutable: true))
        }
    }

    // MARK: - Errors

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case insufficientGrant
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for call history database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .insufficientGrant:
                return
                    "The stored grant covers the call history database file alone; grant the CallHistoryDB folder instead"
            case .userDeclinedAccess:
                return "User declined to grant access to the call history database"
            case .invalidFileSelected:
                return
                    "Call history database access denied or the selection is not the CallHistoryDB folder"
            case .fileNotReadable:
                return "The selected folder has no readable \(callHistoryDatabaseName)"
            }
        }
    }

    private enum ArgumentError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message):
                return "Invalid argument: \(message)"
            }
        }
    }

    private enum CallError: LocalizedError {
        case missingPhoneNumber
        case invalidPhoneNumber(String)
        case openFailed

        var errorDescription: String? {
            switch self {
            case .missingPhoneNumber:
                return "A phone number is required"
            case .invalidPhoneNumber(let number):
                return "Invalid phone number: \(number)"
            case .openFailed:
                return
                    "Failed to start the call. Check that your iPhone is nearby and Calls on Other Devices is enabled."
            }
        }
    }

    // MARK: - UI

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Call History Database Access Required"
        alert.informativeText = """
            To read your phone call history, we need access to your CallHistoryDB folder: \
            the database and the log new calls are written to first.

            In the next screen, please select the `CallHistoryDB` folder and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFolderPicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message =
            "Please select your call history folder (~/Library/Application Support/CallHistoryDB)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: callHistoryDirectoryPath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            isCallHistoryDirectory(url)
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .securityScopeAllowOnlyReadAccess,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: callHistoryDatabaseBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    private func isCallHistoryDirectory(_ url: URL) -> Bool {
        return url.lastPathComponent == "CallHistoryDB"
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the CallHistoryDB folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = isCallHistoryDirectory(url)
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

// MARK: -

/// A read-only connection to the Call History database.
private final class CallHistoryDatabase {
    private let connection: OpaquePointer

    /// Opens the store read-only.
    /// With `immutable`, SQLite ignores the write-ahead log and never touches the `-wal`
    /// and `-shm` files, so records since the last checkpoint are not visible.
    init(path: String, immutable: Bool) throws {
        var filename = path
        var flags = SQLITE_OPEN_READONLY
        if immutable {
            var components = URLComponents()
            components.scheme = "file"
            components.path = path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else {
                throw SQLiteError(message: "cannot build a URI for \(path)")
            }
            filename = uri
            flags |= SQLITE_OPEN_URI
        }

        var connection: OpaquePointer?
        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(connection) }
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        self.connection = connection!
    }

    deinit {
        sqlite3_close(connection)
    }

    func fetch(_ request: CallRecord.FetchRequest) throws -> [CallRecord] {
        let (sql, bindings) = request.statement

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        var records: [CallRecord] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            records.append(CallRecord(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        return records
    }
}

private struct SQLiteError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return "SQLite error: \(message)"
    }
}

/// A value bound to a `?` placeholder in a prepared statement.
private enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int)

    func bind(to statement: OpaquePointer?, at index: Int32) {
        switch self {
        case .text(let string):
            sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
        case .double(let double):
            sqlite3_bind_double(statement, index, double)
        case .int(let int):
            sqlite3_bind_int(statement, index, Int32(clamping: int))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A row of the `ZCALLRECORD` table.
private struct CallRecord {
    enum CallType: String {
        case incoming
        case outgoing
        case missed

        /// The SQL predicate that selects records of this type.
        fileprivate var predicate: String {
            switch self {
            case .incoming: return "ZORIGINATED = 0 AND ZANSWERED = 1"
            case .outgoing: return "ZORIGINATED = 1"
            case .missed: return "ZORIGINATED = 0 AND ZANSWERED = 0"
            }
        }
    }

    let id: Int
    let address: String?
    let name: String?
    let date: Date
    let duration: TimeInterval
    let isOriginated: Bool
    let isAnswered: Bool
    let serviceProvider: String?

    var callType: CallType {
        if isOriginated {
            return .outgoing
        } else if isAnswered {
            return .incoming
        } else {
            return .missed
        }
    }

    /// Reads the current row of a statement prepared from `FetchRequest.statement`.
    fileprivate init(_ statement: OpaquePointer?) {
        func text(_ column: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            let string = String(cString: cString)
            return string.isEmpty ? nil : string
        }

        id = Int(sqlite3_column_int64(statement, 0))
        address = text(1)
        name = text(2)
        // ZDATE is stored as seconds since the Core Data reference date (2001-01-01)
        date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
        duration = sqlite3_column_double(statement, 4)
        isOriginated = sqlite3_column_int(statement, 5) == 1
        isAnswered = sqlite3_column_int(statement, 6) == 1
        serviceProvider = text(7)
    }
}

extension CallRecord {
    struct FetchRequest {
        /// Phone number or contact name to match (partial, case-insensitive).
        var participant: String?
        /// Start of the date range (inclusive).
        var startDate: Date?
        /// End of the date range (exclusive).
        var endDate: Date?
        var callType: CallType?
        var limit: Int

        /// The SQL and its bound values, in placeholder order.
        fileprivate var statement: (sql: String, bindings: [SQLiteValue]) {
            var conditions: [String] = []
            var bindings: [SQLiteValue] = []

            if let participant {
                conditions.append("(ZADDRESS LIKE ? OR ZNAME LIKE ?)")
                bindings += [.text("%\(participant)%"), .text("%\(participant)%")]
            }
            if let startDate {
                conditions.append("ZDATE >= ?")
                bindings.append(.double(startDate.timeIntervalSinceReferenceDate))
            }
            if let endDate {
                conditions.append("ZDATE < ?")
                bindings.append(.double(endDate.timeIntervalSinceReferenceDate))
            }
            if let callType {
                conditions.append(callType.predicate)
            }
            bindings.append(.int(limit))

            let whereClause =
                conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT Z_PK, ZADDRESS, ZNAME, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZSERVICE_PROVIDER
                FROM ZCALLRECORD
                \(whereClause)
                ORDER BY ZDATE DESC
                LIMIT ?
                """
            return (sql, bindings)
        }
    }

    /// The record as a JSON object for tool output.
    var value: Value {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        var object: [String: Value] = [
            "@id": .string(String(id)),
            "phoneNumber": .string(address ?? "Unknown"),
            "callType": .string(callType.rawValue),
            "date": .string(date.formatted(.iso8601)),
            "duration": .string(minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"),
            "durationSeconds": .double(duration),
            "serviceProvider": .string(serviceProvider ?? "unknown"),
        ]
        if let name {
            object["name"] = .string(name)
        }
        return .object(object)
    }
}

// MARK: -

/// A CommunicateAction model following Schema.org ontology (https://schema.org/CommunicateAction)
private struct CommunicateAction: Hashable, Sendable {
    /// Unique identifier for the action
    var identifier: String?

    /// Description of the action
    var description: String?

    /// Action status values based on Schema.org ActionStatusType
    enum Status: String, Codable, Hashable, Sendable {
        case active = "ActiveActionStatus"
        case completed = "CompletedActionStatus"
        case failed = "FailedActionStatus"
        case potential = "PotentialActionStatus"
    }

    /// Status of the action
    var status: Status?

    /// The participant who receives the communication
    var recipient: Person?

    init(recipient: Person? = nil, status: Status? = nil, description: String? = nil) {
        self.recipient = recipient
        self.status = status
        self.description = description
    }
}

extension CommunicateAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case description
        case status = "actionStatus"
        case recipient
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: JSONLDCodingKey<CodingKeys>.self)

        // Encode @context if we're at the root level
        if encoder.codingPath.isEmpty {
            try container.encode("https://schema.org", forKey: .context)
        }

        // Encode @type
        try container.encode(String(describing: Self.self), forKey: .type)

        // Encode @id
        try container.encodeIfPresent(identifier, forKey: .id)

        // Encode properties
        try container.encodeIfPresent(description, forKey: .attribute(.description))
        try container.encodeIfPresent(status?.rawValue, forKey: .attribute(.status))
        try container.encodeIfPresent(recipient, forKey: .attribute(.recipient))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JSONLDCodingKey<CodingKeys>.self)

        // Verify type is correct
        let describedType = String(describing: Self.self)
        let decodedType = try container.decode(String.self, forKey: .type)
        guard decodedType == describedType else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected type to be '\(describedType)', but found \(decodedType)"
            )
        }

        // Decode @id
        identifier = try container.decodeIfPresent(String.self, forKey: .id)

        // Decode properties
        description = try container.decodeIfPresent(String.self, forKey: .attribute(.description))
        if let statusString = try container.decodeIfPresent(
            String.self,
            forKey: .attribute(.status)
        ) {
            status = Status(rawValue: statusString)
        }
        recipient = try container.decodeIfPresent(Person.self, forKey: .attribute(.recipient))
    }
}

extension Person {
    /// Initialize a Person known only by a telephone number
    fileprivate init(telephone: String) {
        self.init(name: "")
        self.givenName = nil
        self.telephone = [telephone]
    }
}
