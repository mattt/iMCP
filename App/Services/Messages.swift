import AppKit
import OSLog
import SQLite3
import iMessage

private let log = Logger.service("messages")
private let messagesDirectoryPath = "/Users/\(NSUserName())/Library/Messages"
private let messagesDatabasePath = messagesDirectoryPath + "/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    /// Logged once per launch when the stored grant covers `chat.db` alone.
    private var warnedAboutFileGrant = false

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
            if !warnedAboutFileGrant {
                warnedAboutFileGrant = true
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

        let selectedURL = try await showFolderPicker()

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
            description: "Fetch messages from the Messages app",
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
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
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

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let isReadFilter = arguments["isRead"]?.boolValue
            let limit = arguments["limit"]?.intValue

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
            for message in try db.fetch(request) {
                guard messages.count < (limit ?? defaultLimit) else { break }
                guard !message.text.isEmpty else { continue }

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
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                var object: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "isRead": .bool(message.isRead),
                ]
                if let readAt = message.readAt {
                    object["dateRead"] = .string(readAt.formatted(.iso8601))
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
        fileprivate let scopedURL: URL?

        /// Ends the security scope. Call it after the last read on `database`.
        func stop() {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    private func openDatabase() throws -> DatabaseAccess {
        if canAccessDatabaseAtDefaultPath {
            return DatabaseAccess(database: try iMessage.Database(), scopedURL: nil)
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
            return DatabaseAccess(database: database, scopedURL: grant.url)
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

    @MainActor
    private func showFolderPicker() async throws -> URL {
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

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            isMessagesDirectory(url)
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
