import AppKit
import OSLog
import TopoText

private let log = Logger.service("notes")
private let notesContainerURL = TopoText.Store.defaultRoot
private let notesDatabaseName = "NoteStore.sqlite"
private let notesDatabasePath = notesContainerURL.appendingPathComponent(notesDatabaseName).path
private let notesContainerBookmarkKey: String = "me.mattt.iMCP.notesContainerBookmark"

/// Reads notes from the database that the Notes app keeps on this Mac.
///
/// Apple provides no public API for Notes,
/// so this service reads the app's database with TopoText, which never writes to it.
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
            try self.checkDatabaseAccess()
            let folders = try await self.withStore { try await $0.folders() }

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
                "Fetch notes from the Notes app, most recently edited first, with each note's title, preview, folder, and dates. Use notes_read for a note's full contents. Notes in Recently Deleted are left out unless that folder is requested. When more notes may match, the result has a nextCursor; pass it as cursor, with the same filters, to continue.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description:
                            "Text to search for in note titles and contents, including tags, tables, and text recognized in images (case-insensitive)"
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
                        default: .int(TopoText.Note.FetchRequest.defaultLimit),
                        minimum: 1,
                        maximum: TopoText.Note.FetchRequest.maximumLimit
                    ),
                    "cursor": .string(
                        description: "The nextCursor of a previous result, to fetch the notes after it"
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

            var request = TopoText.Note.FetchRequest()
            request.query = try self.argument("query", in: arguments, as: \.stringValue)
            if let limit = try self.argument("limit", in: arguments, as: \.intValue) {
                request.limit = limit
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
            if let cursor = try self.argument("cursor", in: arguments, as: \.stringValue) {
                guard let cursor = TopoText.Note.FetchRequest.Cursor(cursor) else {
                    throw ArgumentError.invalid("cursor must be the nextCursor of a previous result")
                }
                request.cursor = cursor
            }
            let folderArgument = try self.argument("folder", in: arguments, as: \.stringValue)

            try self.checkDatabaseAccess()
            let baseRequest = request
            let (result, folders) = try await self.withStore { store in
                // The folders and the notes come from one snapshot, so they agree.
                try await store.withSnapshot { snapshot in
                    let folders = try snapshot.folders()
                    var request = baseRequest
                    if let folderArgument {
                        let matches = folders.filter { $0.matches(folderArgument) }
                        guard !matches.isEmpty else {
                            throw ArgumentError.invalid(
                                "no folder is named or identified by \"\(folderArgument)\"; use notes_folders to list them"
                            )
                        }
                        request.folderIDs = Set(matches.map(\.id))
                    }
                    return (try snapshot.search(request), folders)
                }
            }
            if !result.unreadableNoteIDs.isEmpty {
                log.warning(
                    "Matched \(result.unreadableNoteIDs.count) notes by title and preview alone, because their contents could not be read"
                )
            }

            log.debug("Successfully fetched \(result.notes.count) notes")
            var list: [String: Value] = [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Notes",
                "numberOfItems": .int(result.notes.count),
                "itemListElement": .array(result.notes.map { .object($0.properties(in: folders)) }),
            ]
            if let nextCursor = result.nextCursor {
                list["nextCursor"] = .string(nextCursor.description)
            }
            return list
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
                let argument = try self.argument("id", in: arguments, as: \.stringValue),
                let id = TopoText.Note.ID(argument.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw ArgumentError.invalid("id must be the @id of a note")
            }
            let isMarkdown: Bool
            switch try self.argument("format", in: arguments, as: \.stringValue) ?? "markdown" {
            case "markdown": isMarkdown = true
            case "plain": isMarkdown = false
            default: throw ArgumentError.invalid("format must be one of: markdown, plain")
            }

            try self.checkDatabaseAccess()
            let (note, content, folders) = try await self.withStore { store in
                try await store.withSnapshot { snapshot in
                    (try snapshot.note(for: id), try snapshot.content(for: id), try snapshot.folders())
                }
            }

            var object = note.properties(in: folders)
            object["@context"] = "https://schema.org"
            object["encodingFormat"] = .string(isMarkdown ? "text/markdown" : "text/plain")
            object["text"] = .string(isMarkdown ? content.markdown() : content.plainText())
            return object
        }
    }

    // MARK: - Database Access

    /// Ensures the Notes database is readable, asking the user to grant access if needed.
    ///
    /// The grant has to cover the `group.com.apple.notes` folder, not just the database file.
    /// The store is a WAL-mode SQLite database, so SQLite also opens the `-wal` and `-shm`
    /// files next to it, and Notes writes recent edits to the log first.
    ///
    /// Only the menu-bar toggle calls this, through `activate()`;
    /// tool calls use `checkDatabaseAccess()` instead.
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

        // The picker grants access to the folder for as long as the app runs.
        try await TopoText.Store(root: selectedURL).checkAccess()

        try storeBookmark(for: selectedURL)
        log.debug("Granted access to Notes database")
    }

    /// Throws unless the Notes database is readable, without asking for access.
    ///
    /// A tool call can arrive when nobody is at the Mac,
    /// so it must not park the server behind an alert or a folder picker,
    /// and concurrent calls must not stack them.
    /// The error tells the client how to grant access from the iMCP menu instead.
    private func checkDatabaseAccess() throws {
        if canAccessDatabaseAtDefaultPath {
            return
        }
        guard UserDefaults.standard.data(forKey: notesContainerBookmarkKey) != nil else {
            throw DatabaseAccessError.accessNotGranted
        }
        guard canAccessDatabaseUsingBookmark else {
            throw DatabaseAccessError.grantUnusable
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

    /// Runs an operation on the store, inside the grant for the bookmarked folder
    /// unless the database is readable at the default path.
    /// Errors from TopoText are rethrown as `StoreError`, which describes them for the client.
    private func withStore<T>(_ operation: (TopoText.Store) async throws -> T) async throws -> T {
        do {
            if canAccessDatabaseAtDefaultPath {
                return try await operation(TopoText.Store(root: notesContainerURL))
            }

            let directory = try resolveBookmarkedContainer()

            // The grant must stay open until the store's call returns:
            // SQLite opens the write-ahead log lazily on the first statement.
            guard directory.startAccessingSecurityScopedResource() else {
                log.error("Failed to start accessing security-scoped resource")
                throw DatabaseAccessError.securityScopeAccessFailed
            }
            defer { directory.stopAccessingSecurityScopedResource() }
            return try await operation(TopoText.Store(root: directory))
        } catch let error as TopoText.NotesError {
            throw StoreError(underlying: error)
        } catch let error as TopoText.Note.FetchRequest.ValidationError {
            throw StoreError(underlying: error)
        }
    }

    // MARK: - Errors

    // The server reports a tool's error by interpolating it,
    // so each error type describes itself with its readable message.
    private enum DatabaseAccessError: LocalizedError, CustomStringConvertible {
        case noBookmarkFound
        case securityScopeAccessFailed
        case userDeclinedAccess
        case invalidFolderSelected
        case accessNotGranted
        case grantUnusable

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for Notes database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .userDeclinedAccess:
                return "User declined to grant access to the Notes database"
            case .accessNotGranted:
                return
                    "The Notes folder (~/Library/Group Containers/group.com.apple.notes) has not been granted; switch Notes off and on in the iMCP menu and select it when asked"
            case .grantUnusable:
                return
                    "Could not read the Notes database through the stored grant; switch Notes off and on in the iMCP menu to grant the Notes folder again"
            case .invalidFolderSelected:
                return
                    "Notes database access denied or the selection is not the group.com.apple.notes folder"
            }
        }
    }

    private enum ArgumentError: LocalizedError, CustomStringConvertible {
        case invalid(String)

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .invalid(let message):
                return "Invalid argument: \(message)"
            }
        }
    }

    /// An error from TopoText, with a description for the client.
    /// TopoText's errors conform only to `LocalizedError`,
    /// so interpolating one would show its case name instead of its message.
    private struct StoreError: LocalizedError, CustomStringConvertible {
        let underlying: any Swift.Error

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch underlying {
            case TopoText.NotesError.storeNotFound:
                return
                    "The Notes folder has no Notes database; switch Notes off and on in the iMCP menu and select the group.com.apple.notes folder"
            case TopoText.NotesError.storeNotReadable:
                return
                    "The Notes database or its write-ahead log files cannot be read; switch Notes off and on in the iMCP menu to grant the Notes folder again"
            case is TopoText.Note.FetchRequest.ValidationError:
                return "Invalid argument: \(underlying.localizedDescription)"
            default:
                return underlying.localizedDescription
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
        openPanel.directoryURL = notesContainerURL.deletingLastPathComponent()
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

extension TopoText.Folder {
    /// Whether the folder has the given identifier or name (ignoring case and diacritics).
    fileprivate func matches(_ nameOrIdentifier: String) -> Bool {
        let argument = nameOrIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.description == argument
            || name.compare(argument, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The folder as a JSON object for tool output.
    fileprivate func value(in folders: [TopoText.Folder]) -> Value {
        var object: [String: Value] = [
            "@id": .string(id.description),
            "name": .string(name),
            "numberOfItems": .int(noteCount),
        ]
        if let accountName = account?.name {
            object["account"] = .string(accountName)
        }
        if let parentID, let parent = folders.first(where: { $0.id == parentID }) {
            object["parentFolder"] = [
                "@id": .string(parent.id.description),
                "name": .string(parent.name),
            ]
        }
        if isRecentlyDeleted {
            object["isRecentlyDeleted"] = true
        }
        return .object(object)
    }
}

extension TopoText.Note {
    /// The note's metadata as the properties of a JSON object for tool output.
    fileprivate func properties(in folders: [TopoText.Folder]) -> [String: Value] {
        var object: [String: Value] = [
            "@type": "NoteDigitalDocument",
            "@id": .string(id.description),
            "name": .string(title.isEmpty ? "New Note" : title),
        ]
        if let snippet, !snippet.isEmpty {
            object["abstract"] = .string(snippet)
        }
        if let creationDate {
            object["dateCreated"] = .string(creationDate.formatted(.iso8601))
        }
        if let modificationDate {
            object["dateModified"] = .string(modificationDate.formatted(.iso8601))
        }
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            var isPartOf: [String: Value] = [
                "@id": .string(folder.id.description),
                "name": .string(folder.name),
            ]
            if let accountName = folder.account?.name {
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
