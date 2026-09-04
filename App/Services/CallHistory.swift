import AppKit
import OSLog
import SQLite3

private let log = Logger.service("callhistory")
private let callHistoryDatabasePath =
    "/Users/\(NSUserName())/Library/Application Support/CallHistoryDB/CallHistory.storedata"
private let callHistoryDatabaseBookmarkKey: String = "me.mattt.iMCP.callHistoryDatabaseBookmark"
private let defaultLimit = 30

// Apple's Core Data epoch: 2001-01-01 00:00:00 UTC
private let coreDataEpoch: TimeInterval = 978_307_200

final class CallHistoryService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = CallHistoryService()

    func activate() async throws {
        log.debug("Starting call history service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated call history service")
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Call history service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "callhistory_fetch",
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
                        default: .int(defaultLimit)
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
            try await self.activate()

            let participant = arguments["participant"]?.stringValue
            let callTypeFilter = arguments["call_type"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? defaultLimit

            var startDate: Date?
            var endDate: Date?
            if let startStr = arguments["start"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startStr)
            {
                startDate = parsedStart.date
            }
            if let endStr = arguments["end"]?.stringValue,
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endStr)
            {
                endDate = parsedEnd.date
            }

            let databaseURL = try self.resolveDatabaseURL()
            let calls = try self.fetchCalls(
                from: databaseURL,
                participant: participant,
                startDate: startDate,
                endDate: endDate,
                callTypeFilter: callTypeFilter,
                limit: limit
            )

            log.debug("Successfully fetched \(calls.count) calls")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Call History",
                "numberOfItems": .int(calls.count),
                "itemListElement": Value.array(calls.map({ .object($0) })),
            ]
        }
    }

    // MARK: - Database Access

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: callHistoryDatabasePath)
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    private func resolveDatabaseURL() throws -> URL {
        if canAccessDatabaseAtDefaultPath {
            return URL(fileURLWithPath: callHistoryDatabasePath)
        }
        return try resolveBookmarkURL()
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

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T
    {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    // MARK: - SQLite Query

    private func fetchCalls(
        from databaseURL: URL,
        participant: String?,
        startDate: Date?,
        endDate: Date?,
        callTypeFilter: String?,
        limit: Int
    ) throws -> [[String: Value]] {
        let accessBlock: (URL) throws -> [[String: Value]] = { url in
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
                throw DatabaseAccessError.sqliteError(errorMessage)
            }
            defer { sqlite3_close(db) }

            // Build query with filters
            var conditions: [String] = []
            var params: [Any] = []

            if let participant = participant {
                conditions.append("(c.ZADDRESS LIKE ? OR c.ZNAME LIKE ?)")
                params.append("%\(participant)%")
                params.append("%\(participant)%")
            }

            if let startDate = startDate {
                let coreDataTimestamp = startDate.timeIntervalSince1970 - coreDataEpoch
                conditions.append("c.ZDATE >= ?")
                params.append(coreDataTimestamp)
            }

            if let endDate = endDate {
                let coreDataTimestamp = endDate.timeIntervalSince1970 - coreDataEpoch
                conditions.append("c.ZDATE < ?")
                params.append(coreDataTimestamp)
            }

            if let callTypeFilter = callTypeFilter {
                switch callTypeFilter.lowercased() {
                case "incoming":
                    conditions.append("c.ZORIGINATED = 0 AND c.ZANSWERED = 1")
                case "outgoing":
                    conditions.append("c.ZORIGINATED = 1")
                case "missed":
                    conditions.append("c.ZORIGINATED = 0 AND c.ZANSWERED = 0")
                default:
                    break
                }
            }

            let whereClause =
                conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            let query = """
                SELECT
                    c.Z_PK,
                    c.ZADDRESS,
                    c.ZNAME,
                    c.ZDATE,
                    c.ZDURATION,
                    c.ZORIGINATED,
                    c.ZANSWERED,
                    c.ZSERVICE_PROVIDER
                FROM ZCALLRECORD c
                \(whereClause)
                ORDER BY c.ZDATE DESC
                LIMIT ?
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                throw DatabaseAccessError.sqliteError(errorMessage)
            }
            defer { sqlite3_finalize(stmt) }

            // Bind parameters
            var paramIndex: Int32 = 1
            for param in params {
                if let stringParam = param as? String {
                    sqlite3_bind_text(
                        stmt, paramIndex, (stringParam as NSString).utf8String, -1, nil)
                } else if let doubleParam = param as? Double {
                    sqlite3_bind_double(stmt, paramIndex, doubleParam)
                } else if let timeInterval = param as? TimeInterval {
                    sqlite3_bind_double(stmt, paramIndex, timeInterval)
                }
                paramIndex += 1
            }
            sqlite3_bind_int(stmt, paramIndex, Int32(limit))

            var calls: [[String: Value]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                // Columns: 0=Z_PK, 1=ZADDRESS, 2=ZNAME, 3=ZDATE, 4=ZDURATION,
                //          5=ZORIGINATED, 6=ZANSWERED, 7=ZSERVICE_PROVIDER
                let id = Int(sqlite3_column_int64(stmt, 0))

                let address: String
                if let cStr = sqlite3_column_text(stmt, 1) {
                    address = String(cString: cStr)
                } else {
                    address = "Unknown"
                }

                let name: String?
                if let cStr = sqlite3_column_text(stmt, 2) {
                    let n = String(cString: cStr)
                    name = n.isEmpty ? nil : n
                } else {
                    name = nil
                }

                let coreDataDate = sqlite3_column_double(stmt, 3)
                let unixTimestamp = coreDataDate + coreDataEpoch
                let date = Date(timeIntervalSince1970: unixTimestamp)

                let duration = sqlite3_column_double(stmt, 4)
                let originated = sqlite3_column_int(stmt, 5)
                let answered = sqlite3_column_int(stmt, 6)

                let callType: String
                if originated == 1 {
                    callType = "outgoing"
                } else if answered == 1 {
                    callType = "incoming"
                } else {
                    callType = "missed"
                }

                let serviceProvider: String
                if let cStr = sqlite3_column_text(stmt, 7) {
                    serviceProvider = String(cString: cStr)
                } else {
                    serviceProvider = "unknown"
                }

                let durationMinutes = Int(duration) / 60
                let durationSeconds = Int(duration) % 60
                let durationStr =
                    durationMinutes > 0
                    ? "\(durationMinutes)m \(durationSeconds)s" : "\(durationSeconds)s"

                var entry: [String: Value] = [
                    "@id": .string(String(id)),
                    "phoneNumber": .string(address),
                    "callType": .string(callType),
                    "date": .string(date.formatted(.iso8601)),
                    "duration": .string(durationStr),
                    "durationSeconds": .double(duration),
                    "serviceProvider": .string(serviceProvider),
                ]
                if let name = name {
                    entry["name"] = .string(name)
                }

                calls.append(entry)
            }

            return calls
        }

        // Use security-scoped access if needed
        if canAccessDatabaseAtDefaultPath {
            return try accessBlock(databaseURL)
        } else {
            return try withSecurityScopedAccess(databaseURL) { url in
                try accessBlock(url)
            }
        }
    }

    // MARK: - Errors

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable
        case sqliteError(String)

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for call history database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .userDeclinedAccess:
                return "User declined to grant access to the call history database"
            case .invalidFileSelected:
                return "Call history database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            case .sqliteError(let message):
                return "SQLite error: \(message)"
            }
        }
    }

    // MARK: - UI

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Call History Database Access Required"
        alert.informativeText = """
            To read your phone call history, we need to open your database file.

            In the next screen, please select the file `CallHistory.storedata` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message =
            "Please select the Call History database file (CallHistory.storedata)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [.item]
        openPanel.directoryURL = URL(fileURLWithPath: callHistoryDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "CallHistory.storedata"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: callHistoryDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "CallHistory.storedata"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}
