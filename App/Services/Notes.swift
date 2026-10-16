import AppKit
import OSLog
import SQLite3
import UniformTypeIdentifiers

private let log = Logger.service("notes")
private let notesContainerPath =
    "/Users/\(NSUserName())/Library/Group Containers/group.com.apple.notes"
private let notesDatabaseName = "NoteStore.sqlite"
private let notesDatabasePath = notesContainerPath + "/" + notesDatabaseName
private let notesContainerBookmarkKey: String = "me.mattt.iMCP.notesContainerBookmark"
private let defaultLimit = 30

/// Reads notes from the database that the Notes app keeps on this Mac.
///
/// Apple provides no public API for Notes,
/// so this service reads the app's Core Data store directly and never writes to it.
final class NotesService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = NotesService()

    func activate() async throws {
        log.debug("Starting notes service activation")
        try await requestDatabaseAccess()
        log.debug("Successfully activated notes service")
    }

    var isActivated: Bool {
        get async {
            var isActivated = canAccessDatabaseAtDefaultPath
            // Only probe the bookmark when one exists, so polling a Mac that has
            // not granted access yet does not log an error every time.
            if UserDefaults.standard.data(forKey: notesContainerBookmarkKey) != nil {
                isActivated = isActivated || canAccessDatabaseUsingBookmark
            }
            log.debug("Notes service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "notes_folders",
            description: "List the folders in the Notes app, with their accounts and how many notes each holds",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.requestDatabaseAccess()
            let folders = try self.withStore { try $0.folders() }

            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Note Folders",
                "numberOfItems": .int(folders.count),
                "itemListElement": Value.array(folders.map { $0.value(in: folders) }),
            ]
        }

        Tool(
            name: "notes_fetch",
            description:
                "Fetch notes from the Notes app, most recently edited first, with each note's title, preview, folder, and dates. Use notes_read for a note's full contents. Notes in Recently Deleted are left out unless that folder is requested.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Text to search for in note titles and contents (case-insensitive)"
                    ),
                    "folder": .string(
                        description:
                            "Name or @id of a folder, as returned by notes_folders. Fetches only the notes directly in that folder"
                    ),
                    "start": .string(
                        description:
                            "Start of the range of dates the notes were last edited (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the range of dates the notes were last edited (exclusive). If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "limit": .integer(
                        description: "Maximum notes to return",
                        default: .int(defaultLimit),
                        minimum: 1
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting notes fetch with arguments: \(arguments)")

            let limit = try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            guard limit >= 1 else {
                throw ArgumentError.invalid("limit must be a positive integer")
            }
            var request = NoteRecord.FetchRequest(limit: limit)
            if let query = try self.argument("query", in: arguments, as: \.stringValue) {
                let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                request.query = query.isEmpty ? nil : query
            }
            if let start = try self.argument("start", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: start
                    )
                else {
                    throw ArgumentError.invalid("start must be an ISO 8601 date")
                }
                request.startDate = Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            if let end = try self.argument("end", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: end
                    )
                else {
                    throw ArgumentError.invalid("end must be an ISO 8601 date")
                }
                request.endDate = Calendar.current.normalizedEndDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            let folderArgument = try self.argument("folder", in: arguments, as: \.stringValue)

            try await self.requestDatabaseAccess()
            let (notes, folders) = try self.withStore { store in
                let folders = try store.folders()
                if let folderArgument {
                    let matches = folders.filter { $0.matches(folderArgument) }
                    guard !matches.isEmpty else {
                        throw ArgumentError.invalid(
                            "no folder is named or identified by \"\(folderArgument)\"; use notes_folders to list them"
                        )
                    }
                    request.folderIDs = Set(matches.map(\.id))
                } else {
                    request.excludedFolderIDs = Set(folders.filter(\.isRecentlyDeleted).map(\.id))
                }
                return (try store.notes(request), folders)
            }

            log.debug("Successfully fetched \(notes.count) notes")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Notes",
                "numberOfItems": .int(notes.count),
                "itemListElement": Value.array(notes.map { .object($0.properties(in: folders)) }),
            ]
        }

        Tool(
            name: "notes_read",
            description:
                "Read the full contents of a note from the Notes app, as Markdown with headings, lists, checklists, links, and tables, or as plain text. Attachments such as images and drawings appear as bracketed descriptions. Notes locked with a password can't be read.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "The note @id, as returned by notes_fetch"
                    ),
                    "format": .string(
                        description: "Format of the returned text",
                        default: .string("markdown"),
                        enum: ["markdown", "plain"]
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Note",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard
                let id = try self.argument("id", in: arguments, as: \.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty
            else {
                throw ArgumentError.invalid("id must be the @id of a note")
            }
            let format: NoteRenderer.Format
            switch try self.argument("format", in: arguments, as: \.stringValue) ?? "markdown" {
            case "markdown": format = .markdown
            case "plain": format = .plain
            default: throw ArgumentError.invalid("format must be one of: markdown, plain")
            }

            try await self.requestDatabaseAccess()
            return try self.withStore { store -> Value in
                guard let note = try store.note(identifier: id) else {
                    throw NoteError.notFound(id)
                }
                guard !note.isLocked else {
                    throw NoteError.locked(id)
                }
                guard let text = try store.text(of: note, format: format) else {
                    throw NoteError.noContent(id)
                }

                var object = note.properties(in: try store.folders())
                object["@context"] = "https://schema.org"
                object["encodingFormat"] = .string(format == .markdown ? "text/markdown" : "text/plain")
                object["text"] = .string(text)
                return .object(object)
            }
        }
    }

    // MARK: - Database Access

    /// Ensures the Notes database is readable, asking the user to grant access if needed.
    ///
    /// The grant has to cover the `group.com.apple.notes` folder, not just the database file.
    /// The store is a WAL-mode SQLite database, so SQLite also opens the `-wal` and `-shm`
    /// files next to it, and Notes writes recent edits to the log first.
    private func requestDatabaseAccess() async throws {
        if canAccessDatabaseAtDefaultPath {
            log.debug("Using Notes database at default path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Using Notes database from stored bookmark")
            return
        }

        log.debug("Opening folder picker for manual Notes folder selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard let selectedURL = try await showFolderPicker() else {
            // Dismissing the picker is the same answer as Cancel on the alert.
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        try storeBookmark(for: selectedURL)
        log.debug("Granted access to Notes database")
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
        return FileManager.default.isReadableFile(atPath: notesDatabasePath)
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkedContainer()
            return try withSecurityScopedAccess(url) { _ in
                FileManager.default.isReadableFile(atPath: databaseURL(in: url).path)
            }
        } catch {
            log.error("Error accessing Notes database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent(notesDatabaseName)
    }

    private func resolveBookmarkedContainer() throws -> URL {
        guard
            let bookmarkData = UserDefaults.standard.data(forKey: notesContainerBookmarkKey)
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

    private func withStore<T>(_ operation: (NoteStore) throws -> T) throws -> T {
        if canAccessDatabaseAtDefaultPath {
            return try read(at: notesDatabasePath, operation)
        }

        let directory = try resolveBookmarkedContainer()

        // The grant must stay open until the last read:
        // SQLite opens the write-ahead log lazily on the first statement.
        return try withSecurityScopedAccess(directory) { url in
            try read(at: databaseURL(in: url).path, operation)
        }
    }

    /// Reads the store live, honoring its write-ahead log.
    /// If SQLite cannot open the log's companion files, for example because they are absent
    /// and the folder is read-only, it reads the main file alone instead.
    /// Nothing is lost then: without a log, every record is already in the main file.
    private func read<T>(at path: String, _ operation: (NoteStore) throws -> T) throws -> T {
        do {
            return try operation(NoteStore(path: path, immutable: false))
        } catch let error as SQLiteError {
            log.warning(
                "Live read of the Notes database failed (\(error.message)); retrying without its write-ahead log"
            )
            return try operation(NoteStore(path: path, immutable: true))
        }
    }

    // MARK: - Errors

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case userDeclinedAccess
        case invalidFolderSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for Notes database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .userDeclinedAccess:
                return "User declined to grant access to the Notes database"
            case .invalidFolderSelected:
                return
                    "Notes database access denied or the selection is not the group.com.apple.notes folder"
            case .fileNotReadable:
                return "The selected folder has no readable \(notesDatabaseName)"
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

    private enum NoteError: LocalizedError {
        case notFound(String)
        case locked(String)
        case noContent(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let id):
                return "No note found with identifier \(id)"
            case .locked(let id):
                return "The note with identifier \(id) is locked with a password, so its contents can't be read"
            case .noContent(let id):
                return
                    "The note with identifier \(id) has no contents on this Mac; it may not have finished syncing"
            }
        }
    }

    // MARK: - UI

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Notes Database Access Required"
        alert.informativeText = """
            To read your notes, we need access to the folder where the Notes app keeps them: \
            the database and the log that recent edits are written to first.

            In the next screen, please select the `group.com.apple.notes` folder and click "Grant Access".
            """
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
        openPanel.message =
            "Please select your Notes folder (~/Library/Group Containers/group.com.apple.notes)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: notesContainerPath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isNotesContainer(url) else {
            throw DatabaseAccessError.invalidFolderSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: notesContainerBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    private func isNotesContainer(_ url: URL) -> Bool {
        return url.lastPathComponent == "group.com.apple.notes"
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Notes folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = isNotesContainer(url)
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

// MARK: -

extension NoteFolder {
    /// The folder as a JSON object for tool output.
    fileprivate func value(in folders: [NoteFolder]) -> Value {
        var object: [String: Value] = [
            "@id": .string(identifier),
            "name": .string(name),
            "numberOfItems": .int(noteCount),
        ]
        if let accountName {
            object["account"] = .string(accountName)
        }
        if let parentID, let parent = folders.first(where: { $0.id == parentID }) {
            object["parentFolder"] = [
                "@id": .string(parent.identifier),
                "name": .string(parent.name),
            ]
        }
        if isRecentlyDeleted {
            object["isRecentlyDeleted"] = true
        }
        return .object(object)
    }
}

extension NoteRecord {
    /// The note's metadata as the properties of a JSON object for tool output.
    fileprivate func properties(in folders: [NoteFolder]) -> [String: Value] {
        var object: [String: Value] = [
            "@type": "NoteDigitalDocument",
            "@id": .string(identifier),
            "name": .string(title ?? "New Note"),
        ]
        if let snippet, !snippet.isEmpty {
            object["abstract"] = .string(snippet)
        }
        if let createdAt {
            object["dateCreated"] = .string(createdAt.formatted(.iso8601))
        }
        if let modifiedAt {
            object["dateModified"] = .string(modifiedAt.formatted(.iso8601))
        }
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            var isPartOf: [String: Value] = [
                "@id": .string(folder.identifier),
                "name": .string(folder.name),
            ]
            if let accountName = folder.accountName {
                isPartOf["account"] = .string(accountName)
            }
            object["isPartOf"] = .object(isPartOf)
        }
        if isPinned {
            object["isPinned"] = true
        }
        if isLocked {
            object["isLocked"] = true
        }
        return object
    }
}

// MARK: -

/// A folder in the Notes app.
private struct NoteFolder {
    /// The folder's row in the database.
    let id: Int
    let identifier: String
    let name: String
    /// The row of the folder this one is nested in, if any.
    let parentID: Int?
    let accountName: String?
    /// Whether this is an account's Recently Deleted folder.
    let isRecentlyDeleted: Bool
    let noteCount: Int

    /// Whether the folder has the given identifier or name (ignoring case and diacritics).
    func matches(_ nameOrIdentifier: String) -> Bool {
        let argument = nameOrIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier == argument
            || name.compare(argument, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// A note's row in the database, without its contents.
private struct NoteRecord {
    /// The note's row in the database.
    let id: Int
    let identifier: String
    let title: String?
    /// The preview Notes shows below the title, or nil for a locked note.
    let snippet: String?
    /// The row of the folder that holds the note.
    let folderID: Int?
    let createdAt: Date?
    let modifiedAt: Date?
    let isPinned: Bool
    /// Whether the note is locked with a password, which leaves its contents encrypted.
    let isLocked: Bool
}

extension NoteRecord {
    struct FetchRequest {
        /// Text to match in the title, preview, or contents (case- and diacritic-insensitive).
        var query: String?
        /// Rows of the folders to fetch from, or nil for all folders.
        var folderIDs: Set<Int>?
        /// Rows of folders to leave out when no folder is requested.
        var excludedFolderIDs: Set<Int> = []
        /// Start of the range of modification dates (inclusive).
        var startDate: Date?
        /// End of the range of modification dates (exclusive).
        var endDate: Date?
        var limit: Int
    }
}

/// A read-only connection to the database that the Notes app keeps
/// in `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
///
/// Notes stores accounts, folders, notes, and attachments as rows of one Core Data table,
/// `ZICCLOUDSYNCINGOBJECT`, told apart by entity (`Z_ENT`, named in `Z_PRIMARYKEY`).
/// Columns that several entities define get numbered suffixes, such as `ZTITLE1` for note
/// titles and `ZTITLE2` for folder names, and some move between releases, so the store
/// reads the columns it finds and NULL in place of any it lacks.
/// Note contents are gzip-compressed protocol buffers in `ZICNOTEDATA`.
private final class NoteStore {
    private let connection: OpaquePointer

    /// Opens the store read-only.
    /// With `immutable`, SQLite ignores the write-ahead log and never touches the `-wal`
    /// and `-shm` files, so edits since the last checkpoint are not visible.
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
        sqlite3_busy_timeout(connection, 1000)
    }

    deinit {
        sqlite3_close(connection)
    }

    // MARK: Queries

    /// All folders except smart folders, which hold no notes of their own.
    func folders() throws -> [NoteFolder] {
        let sql = """
            SELECT f.Z_PK, f.ZIDENTIFIER, \(column("f", "ZTITLE2")), \(column("f", "ZPARENT")),
                \(column("a", "ZNAME")), \(isRecentlyDeleted("f")),
                (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                    WHERE \(try isListedNote("n")) AND n.ZFOLDER = f.Z_PK)
            FROM ZICCLOUDSYNCINGOBJECT f
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = \(column("f", "ZOWNER"))
            WHERE f.Z_ENT = ? AND \(notMarkedForDeletion("f"))
                AND COALESCE(LENGTH(\(column("f", "ZSMARTFOLDERQUERYJSON"))), 0) = 0
                AND COALESCE(\(column("f", "ZNEEDSINITIALFETCHFROMCLOUD")), 0) = 0
            """

        var folders: [NoteFolder] = []
        try query(sql, [.int(try entity("ICFolder"))]) { row in
            let isRecentlyDeleted = row.int(5) == 1
            folders.append(
                NoteFolder(
                    id: row.int(0) ?? 0,
                    identifier: row.text(1) ?? "",
                    name: row.text(2) ?? (isRecentlyDeleted ? "Recently Deleted" : "Notes"),
                    parentID: row.int(3),
                    accountName: row.text(4),
                    isRecentlyDeleted: isRecentlyDeleted,
                    noteCount: row.int(6) ?? 0
                )
            )
        }
        return folders.sorted {
            ($0.accountName ?? "", $0.isRecentlyDeleted ? 1 : 0, $0.name.lowercased())
                < ($1.accountName ?? "", $1.isRecentlyDeleted ? 1 : 0, $1.name.lowercased())
        }
    }

    /// Notes matching the request, most recently modified first.
    func notes(_ request: NoteRecord.FetchRequest) throws -> [NoteRecord] {
        var conditions = [try isListedNote("n")]
        var bindings: [SQLiteValue] = []

        if let folderIDs = request.folderIDs {
            conditions.append("n.ZFOLDER IN (\(placeholders(folderIDs.count)))")
            bindings += folderIDs.sorted().map { .int($0) }
        } else if !request.excludedFolderIDs.isEmpty {
            conditions.append("n.ZFOLDER NOT IN (\(placeholders(request.excludedFolderIDs.count)))")
            bindings += request.excludedFolderIDs.sorted().map { .int($0) }
        }
        let modified = column("n", "ZMODIFICATIONDATE1")
        if let startDate = request.startDate {
            conditions.append("\(modified) >= ?")
            bindings.append(.double(startDate.timeIntervalSinceReferenceDate))
        }
        if let endDate = request.endDate {
            conditions.append("\(modified) < ?")
            bindings.append(.double(endDate.timeIntervalSinceReferenceDate))
        }

        // A query can match contents that only decoding reveals,
        // so the rows are filtered here instead of limited in SQL.
        var limitClause = ""
        if request.query == nil {
            limitClause = "LIMIT ?"
            bindings.append(.int(request.limit))
        }

        let sql = """
            SELECT \(noteColumns)
            FROM ZICCLOUDSYNCINGOBJECT n
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(modified) DESC, n.Z_PK DESC
            \(limitClause)
            """

        var notes: [NoteRecord] = []
        try query(sql, bindings) { row in
            notes.append(NoteRecord(row))
        }

        guard let query = request.query else { return notes }
        var matches: [NoteRecord] = []
        for note in notes where matches.count < request.limit {
            if contains(query, in: note) {
                matches.append(note)
            }
        }
        return matches
    }

    /// The note with the given identifier, unless it has been deleted.
    func note(identifier: String) throws -> NoteRecord? {
        let sql = """
            SELECT \(noteColumns)
            FROM ZICCLOUDSYNCINGOBJECT n
            WHERE \(try isListedNote("n")) AND n.ZIDENTIFIER = ?
            LIMIT 1
            """
        var note: NoteRecord?
        try query(sql, [.text(identifier)]) { row in
            note = NoteRecord(row)
        }
        return note
    }

    /// The note's contents, or nil when the database has none for it.
    func text(of note: NoteRecord, format: NoteRenderer.Format) throws -> String? {
        var data: Data?
        // Take the newest row, in case an edit left an older one behind.
        let sql = "SELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE = ? ORDER BY Z_PK DESC LIMIT 1"
        try query(sql, [.int(note.id)]) { row in
            data = row.blob(0)
        }
        guard let data, !data.isEmpty else { return nil }

        let document = try NoteDocument(data: data)
        let attachmentText = try attachmentTextProvider(
            format: format,
            preloading: Set(document.runs.compactMap(\.attachment?.identifier))
        )
        return NoteRenderer(format: format, attachmentText: attachmentText).render(document)
    }

    /// Whether the note's title, preview, or contents contain the query.
    /// Locked notes match by title alone, because their contents are encrypted.
    private func contains(_ query: String, in note: NoteRecord) -> Bool {
        func matches(_ text: String?) -> Bool {
            text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if matches(note.title) || matches(note.snippet) {
            return true
        }
        guard !note.isLocked else { return false }
        do {
            return matches(try text(of: note, format: .plain))
        } catch {
            log.warning("Skipping note \(note.identifier) in search: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns a function that gives the text standing in for each attachment.
    /// The given attachments are read in one query; any others,
    /// such as those in table cells, are read as they come up.
    private func attachmentTextProvider(
        format: NoteRenderer.Format,
        preloading identifiers: Set<String>
    ) throws -> (NoteDocument.AttachmentReference) -> String {
        var attachments = try self.attachments(identifiers: identifiers)
        var lookedUp = identifiers
        var depth = 0

        func text(for reference: NoteDocument.AttachmentReference) -> String {
            if !lookedUp.contains(reference.identifier) {
                lookedUp.insert(reference.identifier)
                if let attachment = try? self.attachments(identifiers: [reference.identifier])[reference.identifier] {
                    attachments[reference.identifier] = attachment
                }
            }
            // Tables can hold attachments, including other tables; stop before a cycle can recur forever.
            guard depth < 4 else { return "" }
            depth += 1
            defer { depth -= 1 }
            return NoteAttachment.text(
                for: reference,
                attachment: attachments[reference.identifier],
                format: format,
                attachmentText: text
            )
        }
        return text
    }

    /// The attachments with the given identifiers, keyed by identifier.
    private func attachments(identifiers: Set<String>) throws -> [String: NoteAttachment] {
        guard !identifiers.isEmpty else { return [:] }
        let sql = """
            SELECT a.ZIDENTIFIER, \(coalesce("a", "ZTYPEUTI1", "ZTYPEUTI")), \(column("a", "ZALTTEXT")),
                \(column("a", "ZTOKENCONTENTIDENTIFIER")), \(coalesce("a", "ZTITLE", "ZUSERTITLE")),
                \(column("a", "ZURLSTRING")), \(column("m", "ZFILENAME")), \(column("a", "ZSUMMARY")),
                CASE WHEN \(column("a", "ZTYPEUTI")) = '\(NoteAttachment.tableType)'
                    THEN \(coalesce("a", "ZMERGEABLEDATA1", "ZMERGEABLEDATA")) END
            FROM ZICCLOUDSYNCINGOBJECT a
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = \(column("a", "ZMEDIA"))
            WHERE a.ZIDENTIFIER IN (\(placeholders(identifiers.count)))
            """
        var attachments: [String: NoteAttachment] = [:]
        try query(sql, identifiers.sorted().map { .text($0) }) { row in
            guard let identifier = row.text(0) else { return }
            let attachment = NoteAttachment(
                identifier: identifier,
                typeIdentifier: row.text(1),
                altText: row.text(2),
                tokenIdentifier: row.text(3),
                title: row.text(4),
                urlString: row.text(5),
                fileName: row.text(6),
                summary: row.text(7),
                tableData: row.blob(8)
            )
            // Should another kind of row share the identifier, keep the one that has a type.
            if attachments[identifier]?.typeIdentifier == nil || attachment.typeIdentifier != nil {
                attachments[identifier] = attachment
            }
        }
        return attachments
    }

    // MARK: Schema

    /// The names of the columns of `ZICCLOUDSYNCINGOBJECT`.
    private lazy var columns: Set<String> = {
        var names: Set<String> = []
        try? query("SELECT name FROM pragma_table_info('ZICCLOUDSYNCINGOBJECT')") { row in
            if let name = row.text(0) {
                names.insert(name)
            }
        }
        return names
    }()

    /// Core Data entity numbers, keyed by entity name.
    /// The numbers differ between databases, so they are looked up rather than assumed.
    private lazy var entities: [String: Int] = {
        var entities: [String: Int] = [:]
        try? query("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY") { row in
            if let name = row.text(0), let number = row.int(1) {
                entities[name] = number
            }
        }
        return entities
    }()

    private func entity(_ name: String) throws -> Int {
        guard let number = entities[name] else {
            throw SQLiteError(message: "the Notes database has no \(name) entity")
        }
        return number
    }

    /// The first of the candidate columns that the table has, qualified by the alias,
    /// or NULL when it has none of them.
    private func column(_ alias: String, _ candidates: String...) -> String {
        guard let name = candidates.first(where: columns.contains) else { return "NULL" }
        return "\(alias).\(name)"
    }

    /// The first non-NULL value among the candidate columns that the table has.
    private func coalesce(_ alias: String, _ candidates: String...) -> String {
        let names = candidates.filter(columns.contains).map { "\(alias).\($0)" }
        switch names.count {
        case 0: return "NULL"
        case 1: return names[0]
        default: return "COALESCE(\(names.joined(separator: ", ")))"
        }
    }

    /// Rows marked for deletion are already deleted and wait for the deletion to sync.
    /// Notes in Recently Deleted are not marked; they are in that folder.
    private func notMarkedForDeletion(_ alias: String) -> String {
        "COALESCE(\(column(alias, "ZMARKEDFORDELETION")), 0) = 0"
    }

    /// A condition matching the notes that the Notes app lists.
    /// Other note rows, such as drafts of Quick Notes, have no title or no folder.
    private func isListedNote(_ alias: String) throws -> String {
        [
            "\(alias).Z_ENT = \(try entity("ICNote"))",
            notMarkedForDeletion(alias),
            "\(column(alias, "ZTITLE1")) IS NOT NULL",
            "\(column(alias, "ZFOLDER")) IS NOT NULL",
        ].joined(separator: " AND ")
    }

    /// An expression that is 1 for an account's Recently Deleted folder and 0 otherwise.
    private func isRecentlyDeleted(_ alias: String) -> String {
        """
        (COALESCE(\(column(alias, "ZFOLDERTYPE")), 0) = \(trashFolderType) \
        OR COALESCE(\(alias).ZIDENTIFIER, '') LIKE 'TrashFolder%')
        """
    }

    /// The select list that `NoteRecord.init(_:)` reads.
    private var noteColumns: String {
        [
            "n.Z_PK",
            "n.ZIDENTIFIER",
            column("n", "ZTITLE1"),
            "NULLIF(\(coalesce("n", "ZSNIPPET", "ZWIDGETSNIPPET")), '')",
            column("n", "ZFOLDER"),
            // Notes moved the creation date between columns across releases.
            coalesce("n", "ZCREATIONDATE3", "ZCREATIONDATE2", "ZCREATIONDATE1"),
            column("n", "ZMODIFICATIONDATE1"),
            column("n", "ZISPINNED"),
            column("n", "ZISPASSWORDPROTECTED"),
        ].joined(separator: ", ")
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func query(
        _ sql: String,
        _ bindings: [SQLiteValue] = [],
        _ body: (SQLiteRow) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try body(SQLiteRow(statement: statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
    }
}

/// The `ZFOLDERTYPE` of an account's Recently Deleted folder.
private let trashFolderType = 1

extension NoteRecord {
    /// Reads the current row of a statement that selects `NoteStore.noteColumns`.
    fileprivate init(_ row: SQLiteRow) {
        id = row.int(0) ?? 0
        identifier = row.text(1) ?? ""
        title = row.text(2)
        isLocked = row.int(8) == 1
        // A locked note's stored preview can still hold text from before it was locked.
        snippet = isLocked ? nil : row.text(3)
        folderID = row.int(4)
        createdAt = row.double(5).map(Date.init(timeIntervalSinceReferenceDate:))
        modifiedAt = row.double(6).map(Date.init(timeIntervalSinceReferenceDate:))
        isPinned = row.int(7) == 1
    }
}

/// The current row of a prepared statement.
private struct SQLiteRow {
    let statement: OpaquePointer?

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func text(_ column: Int32) -> String? {
        guard !isNull(column), let cString = sqlite3_column_text(statement, column) else { return nil }
        let string = String(cString: cString)
        return string.isEmpty ? nil : string
    }

    func int(_ column: Int32) -> Int? {
        isNull(column) ? nil : Int(sqlite3_column_int64(statement, column))
    }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }

    func blob(_ column: Int32) -> Data? {
        guard !isNull(column), let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
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
            sqlite3_bind_int64(statement, index, Int64(int))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: -

/// The text of a note and the attributes of its runs.
///
/// Notes stores each note as a gzip-compressed `NoteStoreProto` protocol buffer
/// in `ZICNOTEDATA.ZDATA`, with this structure (field numbers in brackets):
///
/// - `NoteStoreProto`: `document` [2]
/// - `Document`: `version` [2], `note` [3]
/// - `Note`: `note_text` [2], repeated `attribute_run` [5]
/// - `AttributeRun`: `length` [1], `paragraph_style` [2], `font_weight` [5],
///   `underlined` [6], `strikethrough` [7], `link` [9], `attachment_info` [12]
/// - `ParagraphStyle`: `style_type` [1], `indent_amount` [4], `checklist` [5],
///   `starting_list_item_number` [7], `block_quote` [8]
/// - `Checklist`: `uuid` [1], `done` [2]
/// - `AttachmentInfo`: `attachment_identifier` [1], `type_uti` [2]
///
/// Run lengths count UTF-16 code units, as `NSString` does.
/// A line feed ends a paragraph, and U+2028 breaks a line within one.
/// Each attachment stands in the text as an object replacement character (U+FFFC).
private struct NoteDocument {
    struct ParagraphStyle {
        enum Kind: Int {
            case title = 0
            case heading = 1
            case subheading = 2
            case monospaced = 4
            case bulletedList = 100
            case dashedList = 101
            case numberedList = 102
            case checklist = 103
        }

        /// The style, or nil for body text.
        var kind: Kind?
        var indent = 0
        /// Whether a checklist item is checked.
        var isChecked = false
        /// The number that a numbered list starts from, when it is not 1.
        var startingNumber: Int?
        var isBlockQuote = false

        var isHeading: Bool {
            switch kind {
            case .title, .heading, .subheading: return true
            default: return false
            }
        }

        var isList: Bool {
            switch kind {
            case .bulletedList, .dashedList, .numberedList, .checklist: return true
            default: return false
            }
        }

        fileprivate init(_ message: ProtobufMessage) {
            kind = message.integer(1).flatMap(Kind.init(rawValue:))
            indent = max(0, message.integer(4) ?? 0)
            isChecked = message.message(5)?.integer(2) == 1
            startingNumber = message.integer(7)
            isBlockQuote = (message.integer(8) ?? 0) != 0
        }
    }

    /// An attachment as the note text refers to it.
    struct AttachmentReference {
        let identifier: String
        let typeIdentifier: String?
    }

    struct Run {
        /// The number of UTF-16 code units the run covers.
        var length: Int
        var paragraphStyle: ParagraphStyle?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStrikethrough = false
        var link: String?
        var attachment: AttachmentReference?

        init(length: Int) {
            self.length = length
        }

        fileprivate init(_ message: ProtobufMessage) {
            length = max(0, message.integer(1) ?? 0)
            paragraphStyle = message.message(2).map(ParagraphStyle.init)
            // 1 is bold, 2 italic, and 3 both.
            let fontWeight = message.integer(5) ?? 0
            isBold = fontWeight == 1 || fontWeight == 3
            isItalic = fontWeight == 2 || fontWeight == 3
            isUnderlined = (message.integer(6) ?? 0) != 0
            isStrikethrough = (message.integer(7) ?? 0) != 0
            link = message.string(9).flatMap { $0.isEmpty ? nil : $0 }
            if let info = message.message(12), let identifier = info.string(1), !identifier.isEmpty {
                attachment = AttachmentReference(identifier: identifier, typeIdentifier: info.string(2))
            }
        }
    }

    /// A paragraph of the note and the runs that make it up, without its line feed.
    struct Paragraph {
        var segments: [(text: String, run: Run)] = []
        /// The paragraph style of the run that holds the paragraph's first character.
        var style: ParagraphStyle?
    }

    let text: String
    let runs: [Run]

    /// Decodes the contents of `ZICNOTEDATA.ZDATA`.
    init(data: Data) throws {
        let root = try ProtobufMessage(data.gunzipped())
        guard let note = root.message(2)?.message(3) else {
            throw NoteDecodingError.unrecognizedFormat
        }
        self.init(note)
    }

    /// Reads a `Note` message, as found in note contents and in table cells.
    fileprivate init(_ note: ProtobufMessage) {
        text = note.string(2) ?? ""
        runs = note.messages(5).map(Run.init)
    }

    /// The text split into paragraphs, each with the runs that cover it.
    /// Text past the last run, if any, is treated as body text.
    var paragraphs: [Paragraph] {
        let text = self.text as NSString
        var runs = self.runs
        let covered = runs.reduce(0) { $0 + $1.length }
        if covered < text.length {
            runs.append(Run(length: text.length - covered))
        }

        var paragraphs: [Paragraph] = []
        var current = Paragraph()
        var hasStyle = false
        var offset = 0
        for run in runs where offset < text.length {
            let length = min(run.length, text.length - offset)
            guard length > 0 else { continue }
            let lines = text.substring(with: NSRange(location: offset, length: length))
                .components(separatedBy: "\n")
            offset += length

            for (index, line) in lines.enumerated() {
                let endsParagraph = index < lines.count - 1
                // An empty paragraph's first character is its line feed.
                if !hasStyle, !line.isEmpty || endsParagraph {
                    current.style = run.paragraphStyle
                    hasStyle = true
                }
                if !line.isEmpty {
                    current.segments.append((line, run))
                }
                if endsParagraph {
                    paragraphs.append(current)
                    current = Paragraph()
                    hasStyle = false
                }
            }
        }
        if !current.segments.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }
}

/// A table in a note, decoded from the `MergableDataProto` protocol buffer
/// that Notes stores, gzip-compressed, in the table attachment's `ZMERGEABLEDATA1` column.
///
/// The table is the state of a CRDT: a list of objects (`MergeableDataObjectEntry` [3]
/// of the `MergeableDataObjectData` at [2, 3]), with key names [4], type names [5],
/// and UUIDs [6] in side lists. Objects refer to one another by index (`ObjectID.object_index` [6]).
/// The `com.apple.notes.ICTable` object maps `crRows` and `crColumns` to ordered sets of UUIDs,
/// and `cellColumns` to a dictionary from each column's UUID to a dictionary from each
/// row's UUID to the cell's `Note`.
private struct NoteTable {
    /// The cells, row by row; nil where a cell is empty.
    let rows: [[NoteDocument?]]

    init(data: Data) throws {
        let root = try ProtobufMessage(data.gunzipped())
        guard let objectData = root.message(2)?.message(3) else {
            throw NoteDecodingError.unrecognizedFormat
        }
        let objects = objectData.messages(3)
        let keys = objectData.strings(4)
        let types = objectData.strings(5)
        let uuids = objectData.allBytes(6)

        func name(_ index: Int?, in names: [String]) -> String? {
            guard let index, names.indices.contains(index) else { return nil }
            return names[index]
        }

        /// The object that an `ObjectID` refers to, following registers
        /// (`register_latest` [1]) until it reaches an object with the given field.
        func object(_ reference: ProtobufMessage?, with field: Int) -> ProtobufMessage? {
            var reference = reference
            for _ in 0 ..< 8 {
                guard let index = reference?.integer(6), objects.indices.contains(index) else { return nil }
                let object = objects[index]
                if object.contains(field) {
                    return object
                }
                reference = object.message(1)?.message(2)
            }
            return nil
        }

        /// The index in `uuids` of the UUID that an `ObjectID` refers to,
        /// through an object of type `com.apple.CRDT.NSUUID` (`custom_map` [13]).
        func uuidIndex(_ reference: ProtobufMessage?) -> Int? {
            let entries = object(reference, with: 13)?.message(13)?.messages(3) ?? []
            let entry = entries.first { name($0.integer(1), in: keys) == "UUIDIndex" } ?? entries.first
            guard let index = entry?.message(2)?.integer(2), uuids.indices.contains(index) else { return nil }
            return index
        }

        /// The positions of the rows or columns that an ordered set lists, keyed by the index
        /// of the UUID that cells refer to them by.
        ///
        /// The set's ordering lists UUIDs by position (`array` [1, 1], `attachment` [2]) and maps
        /// each to the UUID of its row or column (`contents` [1, 2]). The set's `elements` [2]
        /// hold the positions that haven't been deleted. A row or column listed twice,
        /// as conflicting moves can leave it, takes its first position, as in Notes.
        func positions(of reference: ProtobufMessage?) -> [Int: Int] {
            guard let orderedSet = object(reference, with: 16)?.message(16),
                let ordering = orderedSet.message(1)
            else { return [:] }

            var contents: [Int: Int] = [:]
            for element in ordering.message(2)?.messages(1) ?? [] {
                if let key = uuidIndex(element.message(1)), let value = uuidIndex(element.message(2)) {
                    contents[key] = value
                }
            }
            let elements = Set((orderedSet.message(2)?.messages(1) ?? []).compactMap { uuidIndex($0.message(1)) })

            var positions: [Int: Int] = [:]
            for attachment in ordering.message(1)?.messages(2) ?? [] {
                guard let uuid = attachment.bytes(2), let index = uuids.firstIndex(of: uuid) else { continue }
                if !elements.isEmpty, !elements.contains(index) {
                    continue
                }
                let value = contents[index] ?? index
                if positions[value] == nil {
                    positions[value] = positions.count
                }
            }
            return positions
        }

        guard
            let table = objects.first(where: {
                name($0.message(13)?.integer(1), in: types) == "com.apple.notes.ICTable"
            })?.message(13)
        else {
            throw NoteDecodingError.unrecognizedFormat
        }

        var rowPositions: [Int: Int] = [:]
        var columnPositions: [Int: Int] = [:]
        var cellColumns: ProtobufMessage?
        for entry in table.messages(3) {
            switch name(entry.integer(1), in: keys) {
            case "crRows":
                rowPositions = positions(of: entry.message(2))
            case "crColumns":
                columnPositions = positions(of: entry.message(2))
            case "cellColumns":
                cellColumns = object(entry.message(2), with: 6)?.message(6)
            default:
                break
            }
        }

        var rows = [[NoteDocument?]](
            repeating: [NoteDocument?](repeating: nil, count: columnPositions.count),
            count: rowPositions.count
        )
        for column in cellColumns?.messages(1) ?? [] {
            guard let columnPosition = uuidIndex(column.message(1)).flatMap({ columnPositions[$0] }) else {
                continue
            }
            for cell in object(column.message(2), with: 6)?.message(6)?.messages(1) ?? [] {
                guard let rowPosition = uuidIndex(cell.message(1)).flatMap({ rowPositions[$0] }),
                    let note = object(cell.message(2), with: 10)?.message(10)
                else { continue }
                rows[rowPosition][columnPosition] = NoteDocument(note)
            }
        }

        // The direction is stored as a string value somewhere among the table's objects.
        let isRightToLeft = objects.contains { object in
            (object.message(13)?.messages(3) ?? []).contains {
                $0.message(2)?.string(4) == "CRTableColumnDirectionRightToLeft"
            }
        }
        self.rows = isRightToLeft ? rows.map { $0.reversed() } : rows
    }
}

/// An attachment's row in the database.
private struct NoteAttachment {
    static let tableType = "com.apple.notes.table"

    let identifier: String
    let typeIdentifier: String?
    /// The text that an inline attachment, such as a tag or mention, displays.
    let altText: String?
    /// The target of an inline link to another note.
    let tokenIdentifier: String?
    let title: String?
    let urlString: String?
    /// The name of the file that holds the attachment's media.
    let fileName: String?
    /// A plain-text summary that Notes keeps for some attachments, such as tables.
    let summary: String?
    /// The contents of a table.
    let tableData: Data?

    /// The text that stands in for an attachment in a rendered note.
    static func text(
        for reference: NoteDocument.AttachmentReference,
        attachment: NoteAttachment?,
        format: NoteRenderer.Format,
        attachmentText: @escaping (NoteDocument.AttachmentReference) -> String
    ) -> String {
        let type = attachment?.typeIdentifier ?? reference.typeIdentifier ?? ""

        // Tags, mentions, links to other notes, and math results.
        if type.hasPrefix("com.apple.notes.inlinetextattachment.") {
            let text = attachment?.altText ?? ""
            if format == .markdown, type.hasSuffix(".link"), let target = attachment?.tokenIdentifier,
                !text.isEmpty
            {
                return "[\(text)](\(target))"
            }
            return text
        }

        if type == tableType {
            do {
                guard let data = attachment?.tableData else { throw NoteDecodingError.unrecognizedFormat }
                let table = try NoteTable(data: data)
                return NoteRenderer.render(table, format: format, attachmentText: attachmentText)
            } catch {
                return attachment?.summary ?? "[Table]"
            }
        }

        if type == "public.url", let url = attachment?.urlString {
            let title = attachment?.title
            switch format {
            case .markdown: return "[\(title ?? url)](\(url))"
            case .plain: return title.map { "\($0) (\(url))" } ?? url
            }
        }

        let kind: String
        switch type {
        case "com.apple.drawing", "com.apple.drawing.2", "com.apple.paper", "com.apple.notes.sketch":
            kind = "Drawing"
        case "com.apple.notes.gallery", "com.apple.paper.doc.scan", "com.apple.paper.doc.pdf":
            kind = "Scanned document"
        default:
            let uniformType = UTType(type)
            if uniformType?.conforms(to: .image) == true {
                kind = "Image"
            } else if uniformType?.conforms(to: .pdf) == true {
                kind = "PDF"
            } else if uniformType?.conforms(to: .audio) == true {
                kind = "Audio"
            } else if uniformType?.conforms(to: .movie) == true {
                kind = "Video"
            } else if uniformType?.conforms(to: .vCard) == true {
                kind = "Contact"
            } else {
                kind = "Attachment"
            }
        }
        if let name = attachment?.title ?? attachment?.fileName {
            return "[\(kind): \(name)]"
        }
        return "[\(kind)]"
    }
}

/// Renders note contents as Markdown or plain text.
private struct NoteRenderer {
    enum Format {
        case markdown
        case plain
    }

    let format: Format
    /// Returns the text that stands in for an attachment.
    let attachmentText: (NoteDocument.AttachmentReference) -> String

    func render(_ document: NoteDocument) -> String {
        let paragraphs = document.paragraphs
        switch format {
        case .plain:
            return paragraphs.map { paragraph in
                paragraph.segments.map(plainText).joined()
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
            }.joined(separator: "\n")
        case .markdown:
            return markdown(paragraphs)
        }
    }

    private func plainText(_ segment: (text: String, run: NoteDocument.Run)) -> String {
        if let attachment = segment.run.attachment {
            return attachmentText(attachment)
        }
        return segment.text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private enum Block: Equatable {
        case text
        case heading
        case list
        case quote
        case code
        case table
    }

    private func markdown(_ paragraphs: [NoteDocument.Paragraph]) -> String {
        var lines: [String] = []
        var lastBlock: Block?
        var code: [String] = []
        // The last number used in a numbered list, by indent level.
        var numbers: [Int: Int] = [:]

        // Adds lines, with a blank line before them when they start a different kind
        // of block, so that each renders on its own.
        func emit(_ block: Block, _ text: String) {
            guard !text.isEmpty else {
                lines.append("")
                return
            }
            if let lastBlock, lastBlock != block || [.heading, .code, .table].contains(block),
                lines.last?.isEmpty == false
            {
                lines.append("")
            }
            lines.append(text)
            lastBlock = block
        }

        func emitCode() {
            guard !code.isEmpty else { return }
            let text = code.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
            // The fence must be longer than any run of backticks in the code.
            var longestRun = 0
            var run = 0
            for character in text {
                run = character == "`" ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            emit(.code, fence + "\n" + text + "\n" + fence)
            code = []
        }

        for paragraph in paragraphs {
            let style = paragraph.style
            if style?.kind == .monospaced {
                code.append(paragraph.segments.map(plainText).joined())
                continue
            }
            emitCode()

            if paragraph.segments.count == 1, let attachment = paragraph.segments[0].run.attachment,
                attachment.typeIdentifier == NoteAttachment.tableType
            {
                numbers = [:]
                emit(.table, attachmentText(attachment))
                continue
            }

            let indent = style?.indent ?? 0
            if style?.kind == .numberedList {
                numbers = numbers.filter { $0.key <= indent }
            } else {
                // Outer numbered lists continue past nested items; anything else ends them.
                numbers = numbers.filter { style?.isList == true && $0.key < indent }
            }

            let content = inlineMarkdown(paragraph.segments)
            var prefix: String
            switch style?.kind {
            case .title: prefix = "# "
            case .heading: prefix = "## "
            case .subheading: prefix = "### "
            case .bulletedList, .dashedList: prefix = "- "
            case .numberedList:
                let number = (numbers[indent] ?? ((style?.startingNumber ?? 1) - 1)) + 1
                numbers[indent] = number
                prefix = "\(number). "
            case .checklist: prefix = style?.isChecked == true ? "- [x] " : "- [ ] "
            case .monospaced, nil: prefix = ""
            }

            let block: Block
            var lineBreak: String
            if style?.isList == true {
                prefix = String(repeating: "    ", count: indent) + prefix
                block = .list
                // Continuation lines line up with the item's text, to stay within the item.
                lineBreak = "\n" + String(repeating: " ", count: prefix.count)
            } else if style?.isHeading == true {
                block = .heading
                lineBreak = " "
            } else {
                block = .text
                lineBreak = "\n"
            }
            if style?.isBlockQuote == true {
                prefix = "> " + prefix
                lineBreak = lineBreak == " " ? " " : "\n> " + lineBreak.dropFirst()
            }
            guard !content.isEmpty else {
                emit(block, style?.isList == true ? prefix.trimmingCharacters(in: .whitespaces) : "")
                continue
            }
            let text = prefix + content.replacingOccurrences(of: "\u{2028}", with: lineBreak)
            emit(style?.isBlockQuote == true ? .quote : block, text)
        }
        emitCode()
        return lines.joined(separator: "\n")
    }

    /// The Markdown for a paragraph's runs: bold, italic, strikethrough, links, and attachments.
    /// Underlining has no Markdown equivalent and is left out.
    private func inlineMarkdown(_ segments: [(text: String, run: NoteDocument.Run)]) -> String {
        // Merge neighboring runs with the same formatting, so that markers are not
        // closed and reopened between them.
        var merged: [(text: String, run: NoteDocument.Run)] = []
        for segment in segments {
            if let last = merged.last, last.run.attachment == nil, segment.run.attachment == nil,
                last.run.isBold == segment.run.isBold, last.run.isItalic == segment.run.isItalic,
                last.run.isStrikethrough == segment.run.isStrikethrough, last.run.link == segment.run.link
            {
                merged[merged.count - 1].text += segment.text
            } else {
                merged.append(segment)
            }
        }

        return merged.map { segment in
            let text = plainText(segment)
            if segment.run.attachment != nil {
                return text
            }
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            // Markers must touch the text they enclose, so surrounding spaces stay outside.
            let leading = String(text.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" })

            var formatted = core
            if segment.run.isStrikethrough {
                formatted = "~~\(formatted)~~"
            }
            switch (segment.run.isBold, segment.run.isItalic) {
            case (true, true): formatted = "***\(formatted)***"
            case (true, false): formatted = "**\(formatted)**"
            case (false, true): formatted = "*\(formatted)*"
            case (false, false): break
            }
            if let link = segment.run.link {
                formatted = "[\(formatted)](\(link))"
            }
            return leading + formatted + trailing
        }.joined()
    }

    /// Renders a table as a Markdown table with the first row as its header,
    /// or as plain text with tabs between cells.
    static func render(
        _ table: NoteTable,
        format: Format,
        attachmentText: @escaping (NoteDocument.AttachmentReference) -> String
    ) -> String {
        let cellRenderer = NoteRenderer(format: .plain, attachmentText: attachmentText)
        let rows = table.rows.map { row in
            row.map { cell in
                var text = cell.map(cellRenderer.render) ?? ""
                while text.hasSuffix("\n") {
                    text.removeLast()
                }
                return text
            }
        }
        guard let header = rows.first, !header.isEmpty else { return "" }

        switch format {
        case .plain:
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .markdown:
            func line(_ cells: [String]) -> String {
                let cells = cells.map {
                    $0.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                }
                return "| " + cells.joined(separator: " | ") + " |"
            }
            return ([line(header), line(header.map { _ in "---" })] + rows.dropFirst().map(line))
                .joined(separator: "\n")
        }
    }
}

private enum NoteDecodingError: LocalizedError {
    case malformedProtobuf
    case malformedGzip
    case unrecognizedFormat

    var errorDescription: String? {
        switch self {
        case .malformedProtobuf:
            return "The note's contents are not a well-formed protocol buffer"
        case .malformedGzip:
            return "The note's contents are not well-formed gzip data"
        case .unrecognizedFormat:
            return "The note's contents are in a format this version of iMCP doesn't recognize"
        }
    }
}

// MARK: -

/// A protocol buffer message, decoded without a schema.
///
/// Fields keep their wire values; the accessors interpret them
/// by the types that the Notes formats use. Where a field repeats,
/// the singular accessors return its last value, as protocol buffers specify.
private struct ProtobufMessage {
    private enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    private var fields: [(number: Int, value: WireValue)] = []

    init(_ data: Data) throws {
        try self.init(ArraySlice(data))
    }

    init(_ bytes: ArraySlice<UInt8>) throws {
        var index = bytes.startIndex

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.endIndex, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
            }
            throw NoteDecodingError.malformedProtobuf
        }

        func readFixed(_ count: Int) throws -> UInt64 {
            guard bytes.endIndex - index >= count else {
                throw NoteDecodingError.malformedProtobuf
            }
            defer { index += count }
            return bytes[index ..< index + count].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        while index < bytes.endIndex {
            let key = try readVarint()
            let number = Int(truncatingIfNeeded: key >> 3)
            switch key & 0x7 {
            case 0:
                fields.append((number, .varint(try readVarint())))
            case 1:
                fields.append((number, .fixed64(try readFixed(8))))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.endIndex - index) else {
                    throw NoteDecodingError.malformedProtobuf
                }
                let end = index + Int(length)
                fields.append((number, .lengthDelimited(bytes[index ..< end])))
                index = end
            case 5:
                fields.append((number, .fixed32(UInt32(truncatingIfNeeded: try readFixed(4)))))
            default:
                // Groups (wire types 3 and 4) are deprecated and absent from these formats.
                throw NoteDecodingError.malformedProtobuf
            }
        }
    }

    func contains(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    /// The value of a varint field, read as a signed 64-bit integer,
    /// which also covers negative `int32` values.
    func integer(_ number: Int) -> Int? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value {
                return Int(Int64(bitPattern: value))
            }
        }
        return nil
    }

    func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        for field in fields.reversed() where field.number == number {
            if case .lengthDelimited(let bytes) = field.value {
                return bytes
            }
        }
        return nil
    }

    func allBytes(_ number: Int) -> [ArraySlice<UInt8>] {
        fields.compactMap { field in
            guard field.number == number, case .lengthDelimited(let bytes) = field.value else { return nil }
            return bytes
        }
    }

    func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func strings(_ number: Int) -> [String] {
        allBytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func message(_ number: Int) -> ProtobufMessage? {
        bytes(number).flatMap { try? ProtobufMessage($0) }
    }

    /// The messages of a repeated field, leaving out any that are malformed.
    func messages(_ number: Int) -> [ProtobufMessage] {
        allBytes(number).compactMap { try? ProtobufMessage($0) }
    }
}

extension Data {
    /// Decompresses gzip data (RFC 1952), the format of note contents and tables.
    fileprivate func gunzipped() throws -> Data {
        // Some rows hold other formats, such as property lists, which aren't note contents.
        guard count >= 18, self[startIndex] == 0x1F, self[startIndex + 1] == 0x8B else {
            throw NoteDecodingError.unrecognizedFormat
        }
        guard self[startIndex + 2] == 8 else {  // Deflate is the only compression method gzip defines.
            throw NoteDecodingError.malformedGzip
        }

        // The header is 10 bytes, followed by optional fields that its flags announce.
        let flags = self[startIndex + 3]
        var offset = startIndex + 10

        func skipZeroTerminatedField() throws {
            guard let terminator = self[offset...].firstIndex(of: 0) else {
                throw NoteDecodingError.malformedGzip
            }
            offset = terminator + 1
        }

        if flags & 0x04 != 0 {  // FEXTRA
            guard endIndex - offset >= 2 else { throw NoteDecodingError.malformedGzip }
            offset += 2 + (Int(self[offset]) | Int(self[offset + 1]) << 8)
            guard offset <= endIndex else { throw NoteDecodingError.malformedGzip }
        }
        if flags & 0x08 != 0 {  // FNAME
            try skipZeroTerminatedField()
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            try skipZeroTerminatedField()
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }
        // The deflate stream ends 8 bytes before the end, ahead of the CRC and size.
        guard endIndex - offset >= 8 else { throw NoteDecodingError.malformedGzip }

        // Foundation's zlib algorithm reads raw deflate data, as gzip wraps it.
        let deflated = self[offset ..< endIndex - 8]
        do {
            return try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw NoteDecodingError.malformedGzip
        }
    }
}
