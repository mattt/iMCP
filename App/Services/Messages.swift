import AppKit
import OSLog
import os
import SQLite3
import iMessage

private let log = Logger.service("messages")
private let messagesDirectoryPath = "/Users/\(NSUserName())/Library/Messages"
private let messagesDatabasePath = messagesDirectoryPath + "/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    /// Whether the once-per-launch warning about a grant on `chat.db` alone has been logged.
    /// Tool calls run concurrently, so the check-and-set is guarded.
    private let fileGrantWarningLogged = OSAllocatedUnfairLock(initialState: false)

    func activate() async throws {
        try await activate(offeringUpgrade: true)
    }

    /// Makes sure the database is reachable, asking for the Messages folder when nothing is
    /// granted yet. `offeringUpgrade` decides what happens with a grant on `chat.db` alone, as
    /// earlier versions requested: that grant cannot reach the write-ahead log next to it,
    /// where Messages keeps everything since its last checkpoint, so the newest messages stay
    /// invisible for hours. The menu-bar toggle passes `true` and offers the folder; tool calls
    /// pass `false` and keep working with the old grant instead of parking the whole server
    /// behind a modal alert that nobody may be there to answer.
    private func activate(offeringUpgrade: Bool) async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        let grant = try? resolveBookmarkedGrant()
        var upgrading = false
        if canAccessDatabaseUsingBookmark {
            switch grant {
            case .directory:
                log.debug("Successfully activated using stored bookmark")
                return
            case .file:
                upgrading = true
            case nil:
                break
            }
        }

        if upgrading, !offeringUpgrade {
            let isFirstWarning = fileGrantWarningLogged.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if isFirstWarning {
                log.warning(
                    "The Messages grant covers chat.db alone, so messages since its last checkpoint are not visible. Switch Messages off and on in the iMCP menu to grant the Messages folder."
                )
            }
            return
        }

        log.debug("Opening folder picker for manual database selection")
        guard try await showDatabaseAccessAlert(upgrading: upgrading) else {
            // Keeping the old grant is a valid answer; the service stays on.
            if upgrading { return }
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard let selectedURL = try await showFolderPicker() else {
            // Dismissing the picker is the same answer as Cancel on the alert.
            if upgrading { return }
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            // A grant on chat.db alone still serves tool calls, but the service is only fully set
            // up once the Messages folder is granted; until then the toggle offers the upgrade.
            var isActivated = canAccessDatabaseAtDefaultPath
            if case .directory = try? resolveBookmarkedGrant() {
                isActivated = isActivated || canAccessDatabaseUsingBookmark
            }
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description:
                "Fetch messages from the Messages app. Each message names the conversation it belongs to (isPartOf), with its participants.",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "isRead": .boolean(
                        description: "If true, fetch read messages; if false, unread incoming; if omitted, fetch all"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                    "attachments": .boolean(
                        description:
                            "List each message's attachments (attachment: name, encodingFormat, contentSize, @id) and include messages that carry attachments but no text",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate(offeringUpgrade: false)

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            // Either bound may be given alone; the other stays open.
            // chat.db stores dates as Int64 nanoseconds since 2001, so the open ends
            // use dates that fit, rather than Date.distantPast and Date.distantFuture.
            let calendar = Calendar.current
            let start = arguments["start"]?.stringValue
                .flatMap { ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: $0) }
                .map { calendar.normalizedStartDate(from: $0.date, isDateOnly: $0.isDateOnly) }
            let end = arguments["end"]?.stringValue
                .flatMap { ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: $0) }
                .map { calendar.normalizedEndDate(from: $0.date, isDateOnly: $0.isDateOnly) }
            var dateRange: Range<Date>?
            if start != nil || end != nil {
                let lowerBound = start ?? Date(timeIntervalSinceReferenceDate: -9_000_000_000)
                let upperBound = end ?? Date(timeIntervalSinceReferenceDate: 9_000_000_000)
                // An end before the start matches nothing.
                dateRange = lowerBound ..< max(lowerBound, upperBound)
            }

            let searchTerm = arguments["query"]?.stringValue
            let isReadFilter = arguments["isRead"]?.boolValue
            let limit = arguments["limit"]?.intValue
            let includeAttachments = arguments["attachments"]?.boolValue ?? false

            // The grant must stay open until the last read: SQLite opens the write-ahead log lazily.
            let access = try self.openDatabase()
            defer { access.stop() }
            let db = access.database
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit ?? -1)"
            )
            // Match the old fetchMessages(with:in:limit:) semantics:
            // no participant filter when no handles matched.
            var predicates: [MessagePredicate] = []
            if !handles.isEmpty {
                predicates.append(.participantHandles(Set(handles)))
            }
            if let dateRange {
                predicates.append(.dateRange(dateRange))
            }
            let request = FetchRequest<Message>(
                predicate: .and(predicates),
                limit: max(limit ?? defaultLimit, 1024)
            )

            let fetched = try db.fetch(request)
            // Attachments are listed in one query per page (chat.db joins them by message rowid).
            let attachmentsByMessage: [String: [[String: Value]]] =
                includeAttachments
                ? try self.attachments(ofMessages: fetched.map { $0.id.rawValue }, in: access)
                : [:]

            // Each chat is looked up once and shared by all of its messages.
            var conversations: [Chat.ID: [String: Value]] = [:]

            for message in fetched {
                guard messages.count < (limit ?? defaultLimit) else { break }
                let attachments = attachmentsByMessage[message.id.rawValue] ?? []
                // An attachment-only message has no text, or just the U+FFFC placeholder
                // Messages stores where the attachment sits in the body.
                // Madrid also renders an attachment placeholder as its guid (`at_0_<UUID>`) on its
                // own line, alone or after the real text: those lines are dropped too.
                let attachmentIDs = Set(attachments.compactMap { $0["@id"]?.stringValue })
                let text =
                    includeAttachments
                    ? message.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { String($0) }
                        .filter { line in
                            let t = line.trimmingCharacters(in: .whitespaces)
                            return !(attachmentIDs.contains(t) || Self.isAttachmentGUID(t))
                        }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : message.text
                guard !text.isEmpty || !attachments.isEmpty else { continue }

                if let isReadFilter {
                    if isReadFilter {
                        guard message.isRead else { continue }
                    } else {
                        guard !message.isFromMe, !message.isRead else { continue }
                    }
                }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                var object: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "isRead": .bool(message.isRead),
                ]
                if let readAt = message.readAt {
                    object["dateRead"] = .string(readAt.formatted(.iso8601))
                }
                if !attachments.isEmpty {
                    object["attachment"] = .array(attachments.map { .object($0) })
                }

                if let chatID = message.chatID {
                    if conversations[chatID] == nil {
                        conversations[chatID] = try self.conversation(for: chatID, in: db)
                    }
                    object["isPartOf"] = conversations[chatID].map { .object($0) }
                }

                messages.append(object)
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }
    }

    /// The attachments of the given messages (by guid), keyed by message guid, in chat.db
    /// order. Hidden attachments (Messages' own plug-in payloads) are left out.
    /// `at_<n>_<UUID>`: the attachment guid Madrid leaves in place of a placeholder.
    private static func isAttachmentGUID(_ s: String) -> Bool {
        s.range(of: #"^at_\d+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    private func attachments(
        ofMessages guids: [String],
        in access: DatabaseAccess
    ) throws -> [String: [[String: Value]]] {
        var result: [String: [[String: Value]]] = [:]
        guard !guids.isEmpty else { return result }
        let raw = try RawDatabase(access)
        defer { raw.close() }
        let chunks = stride(from: 0, to: guids.count, by: 500)
            .map { Array(guids[$0 ..< min($0 + 500, guids.count)]) }
        for chunk in chunks {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT m.guid, a.guid, a.filename, a.transfer_name, a.mime_type, a.total_bytes, a.is_sticker
                FROM message m
                JOIN message_attachment_join j ON j.message_id = m.ROWID
                JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE m.guid IN (\(placeholders)) AND a.hide_attachment = 0
                ORDER BY m.ROWID, a.ROWID
                """
            try raw.query(sql, bindings: chunk) { stmt in
                guard let messageGuid = RawDatabase.text(stmt, 0), let id = RawDatabase.text(stmt, 1)
                else { return }
                var part: [String: Value] = ["@type": "MediaObject", "@id": .string(id)]
                let filename = RawDatabase.text(stmt, 2)
                if let name = RawDatabase.text(stmt, 3) ?? filename.map({ ($0 as NSString).lastPathComponent }),
                    !name.isEmpty
                {
                    part["name"] = .string(name)
                }
                if let mime = RawDatabase.text(stmt, 4), !mime.isEmpty {
                    part["encodingFormat"] = .string(mime)
                }
                part["contentSize"] = .int(Int(sqlite3_column_int64(stmt, 5)))
                if sqlite3_column_int(stmt, 6) != 0 {
                    part["sticker"] = .bool(true)
                }
                result[messageGuid, default: []].append(part)
            }
        }
        return result
    }

    /// A second, read-only SQLite connection on the same grant, for the tables the iMessage
    /// package does not model (attachments). It uses `immutable=1` whenever the package does:
    /// a `.file` grant, or a default path whose write-ahead log is unreadable.
    private final class RawDatabase {
        private var handle: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(_ access: DatabaseAccess) throws {
            let options = access.immutable ? "immutable=1" : "mode=ro"
            let uri = "file:\(access.path)?\(options)"
            var h: OpaquePointer?
            let rc = sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
            guard rc == SQLITE_OK, let h else {
                let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
                if let h { sqlite3_close(h) }
                throw DatabaseAccessError.attachmentsQueryFailed(message)
            }
            sqlite3_busy_timeout(h, 1000)
            handle = h
        }

        func close() {
            if let handle { sqlite3_close(handle) }
            handle = nil
        }

        func query(_ sql: String, bindings: [String], _ row: (OpaquePointer) throws -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DatabaseAccessError.attachmentsQueryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            for (i, value) in bindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), value, -1, RawDatabase.transient)
            }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    try row(stmt)
                } else if rc == SQLITE_DONE {
                    return
                } else {
                    throw DatabaseAccessError.attachmentsQueryFailed(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }

        static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }
    }

    /// Describes the chat a message belongs to:
    /// its identifier, its display name (group chats) and its participants.
    private func conversation(
        for chatID: Chat.ID,
        in db: iMessage.Database
    ) throws -> [String: Value] {
        var conversation: [String: Value] = [
            "@type": "Conversation",
            "@id": .string(chatID.rawValue),
        ]

        let request = FetchRequest<Chat>(predicate: .id(chatID), limit: 1)
        if let chat = try db.fetch(request).first {
            if let name = chat.displayName, !name.isEmpty {
                conversation["name"] = .string(name)
            }
            conversation["participant"] = .array(
                chat.participants.map { .object(["@id": .string($0.rawValue)]) }
            )
        }

        return conversation
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable
        case attachmentsQueryFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or the selection is not the Messages folder"
            case .fileNotReadable:
                return "The selected folder has no readable chat.db"
            case .attachmentsQueryFailed(let message):
                return "Reading attachments from the Messages database failed: \(message)"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
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

    /// What the stored bookmark grants access to.
    private enum BookmarkedGrant {
        /// The Messages folder: `chat.db` together with its write-ahead log.
        case directory(URL)
        /// `chat.db` alone, as stored by earlier versions: the log next to it is unreadable,
        /// so SQLite has to ignore it and messages since the last checkpoint are missing.
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
                return url.appendingPathComponent("chat.db")
            case .file(let url):
                return url
            }
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent("chat.db")
    }

    private func resolveBookmarkedGrant() throws -> BookmarkedGrant {
        let url = try resolveBookmarkURL()
        let isDirectory = try withSecurityScopedAccess(url) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
        }
        return isDirectory ? .directory(url) : .file(url)
    }

    /// An open connection and the security scope it reads through.
    private struct DatabaseAccess {
        let database: iMessage.Database
        /// Where `database` was opened.
        let path: String
        fileprivate let scopedURL: URL?

        /// Whether `database` was opened without its write-ahead log.
        /// Other connections on the same file must open it the same way,
        /// or the sandbox and privacy checks that made Madrid fall back refuse them.
        var immutable: Bool {
            database.accessMode == .immutable
        }

        /// Ends the security scope. Call it after the last read on `database`.
        func stop() {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    private func openDatabase() throws -> DatabaseAccess {
        if canAccessDatabaseAtDefaultPath {
            return DatabaseAccess(
                database: try iMessage.Database(),
                path: messagesDatabasePath,
                scopedURL: nil
            )
        }

        let grant = try resolveBookmarkedGrant()
        guard grant.url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }

        do {
            let database: iMessage.Database
            switch grant {
            case .directory:
                database = try iMessage.Database(path: grant.databaseURL.path, mode: .live)
            case .file:
                // Warned about once, in activate(offeringUpgrade:).
                database = try iMessage.Database(path: grant.databaseURL.path, mode: .immutable)
            }
            return DatabaseAccess(
                database: database,
                path: grant.databaseURL.path,
                scopedURL: grant.url
            )
        } catch {
            grant.url.stopAccessingSecurityScopedResource()
            throw error
        }
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

    @MainActor
    private func showDatabaseAccessAlert(upgrading: Bool) async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        if upgrading {
            alert.informativeText = """
                iMCP can currently read `chat.db` alone. Messages writes new messages to a log \
                next to it first, so the latest ones stay invisible for hours.

                In the next screen, please select the `Messages` folder and click "Grant Access".
                """
        } else {
            alert.informativeText = """
                To read your Messages history, we need access to your Messages folder: the \
                database and the log Messages writes new messages to.

                In the next screen, please select the `Messages` folder and click "Grant Access".
                """
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Returns the selected folder, or nil when the user dismisses the panel.
    @MainActor
    private func showFolderPicker() async throws -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select your Messages folder (~/Library/Messages)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: messagesDirectoryPath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isMessagesDirectory(url) else {
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
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    private func isMessagesDirectory(_ url: URL) -> Bool {
        return url.lastPathComponent == "Messages"
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Messages folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = isMessagesDirectory(url)
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}
