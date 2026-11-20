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

    /// The tools that read notes. `tools` adds the ones that change the Notes app (see `NotesWrite.swift`).
    @ToolBuilder var readTools: [Tool] {
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
                "Fetch notes from the Notes app, most recently edited first, with each note's title, preview, folder, dates, tags (keywords), and the notes it links to (linkedNotes). Tags and links are database records, which may remain after their text is deleted; links set on ordinary text are not listed. Locked and Recently Deleted notes supply no tags or links but can be link targets. Filter by text, folder, edit or creation dates, tags, pinned or locked state, word counts, and what a note contains (checklists, tables, links, attachments). Use notes_read for a note's full contents. Notes in Recently Deleted are left out unless that folder is requested or includeRecentlyDeleted is true. When more notes may match, the result has a nextCursor; pass it as cursor, with the same filters, to continue.",
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
                    "tag": .array(
                        description:
                            "Tags the notes must all have, with or without the leading #, as in [\"groceries\"] (case-insensitive). Reads the contents of each candidate note",
                        items: .string()
                    ),
                    "has": .array(
                        description:
                            "What the notes must all contain. attachment is any image, table, drawing, file, or link card; link is a link in the text or a link card; scan is a scanned document. Reads the contents of each candidate note",
                        items: .string(enum: NoteFeature.allCases.map { .string($0.rawValue) })
                    ),
                    "pinned": .boolean(
                        description: "Only pinned notes when true, only notes that are not pinned when false"
                    ),
                    "locked": .boolean(
                        description:
                            "Only notes locked with a password when true, only notes that are not locked when false"
                    ),
                    "minWords": .integer(
                        description: "Fewest words in a note's contents. Reads the contents of each candidate note",
                        minimum: 0
                    ),
                    "maxWords": .integer(
                        description: "Most words in a note's contents. Reads the contents of each candidate note",
                        minimum: 0
                    ),
                    "createdStart": .string(
                        description:
                            "Start of the range of dates the notes were created (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "createdEnd": .string(
                        description:
                            "End of the range of dates the notes were created (exclusive). If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "includeRecentlyDeleted": .boolean(
                        description:
                            "Include notes in Recently Deleted when no folder is given. Ignored when folder is set",
                        default: false
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
            request.startDate = try self.dateArgument("start", in: arguments, isEnd: false)
            request.endDate = try self.dateArgument("end", in: arguments, isEnd: true)
            request.includesRecentlyDeleted =
                try self.argument("includeRecentlyDeleted", in: arguments, as: \.boolValue) ?? false
            if let cursor = try self.argument("cursor", in: arguments, as: \.stringValue) {
                guard let cursor = TopoText.Note.FetchRequest.Cursor(cursor) else {
                    throw ArgumentError.invalid("cursor must be the nextCursor of a previous result")
                }
                request.cursor = cursor
            }
            let folderArgument = try self.argument("folder", in: arguments, as: \.stringValue)
            let filter = try self.noteFilter(from: arguments)

            try self.checkDatabaseAccess()
            let baseRequest = request
            let (page, folders, tags, links) = try await self.withStore { store in
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
                    let page = try Self.search(request, filter: filter, in: snapshot)
                    // Tags and links come from the database's rows, so they cost no decoding.
                    // A database that can't supply them still gives the page without them.
                    let ids = page.notes.map(\.id)
                    let tags = try readIfSupported { try snapshot.tags(for: ids) } ?? [:]
                    let links = try readIfSupported { try snapshot.links(from: ids) } ?? [:]
                    return (page, folders, tags, links)
                }
            }
            let result = page
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
                "itemListElement": .array(
                    page.notes.map { note in
                        var object = note.properties(in: folders, tags: tags, links: links)
                        object.merge(page.traits[note.id]?.properties ?? [:]) { current, _ in current }
                        return .object(object)
                    }
                ),
            ]
            if let nextCursor = result.nextCursor {
                list["nextCursor"] = .string(nextCursor.description)
            }
            // Without this, a search that skipped some contents looks complete.
            var caveats: [String] = []
            if !result.unreadableNoteIDs.isEmpty {
                list["unreadableNoteIDs"] = .array(result.unreadableNoteIDs.map { .string($0.description) })
                caveats.append(
                    filter.needsContents
                        ? "The contents of the notes in unreadableNoteIDs could not be read, so they were left out of the results because the filters need a note's contents."
                        : "The contents of the notes in unreadableNoteIDs could not be read, so the search matched them by title and preview alone. These notes can contain the query without appearing in the results."
                )
            }
            if let stoppedEarly = page.stoppedEarly {
                switch stoppedEarly {
                case .contentRead:
                    caveats.append(
                        "The search read the contents of \(Self.contentReadLimit) notes without filling the page, so more notes can match. Pass nextCursor as cursor to continue."
                    )
                case .metadataScan:
                    caveats.append(
                        "The search scanned \(Self.metadataScanLimit) notes without filling the page, so more notes can match. Pass nextCursor as cursor to continue."
                    )
                }
            }
            if !caveats.isEmpty {
                list["description"] = .string(caveats.joined(separator: " "))
            }
            return list
        }

        Tool(
            name: "notes_smart_folders",
            description:
                "List the smart folders in the Notes app, with the rules that select their notes. Smart folders collect notes by a query and hold none of their own, so notes_folders leaves them out. rules is the stored query with single-clause and clauses unwrapped and its Recently Deleted filter removed; anything else, such as or clauses, is as stored, and conflicting filters leave rules as stored. includesRecentlyDeleted appears only when true. query is the stored text.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Smart Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.smartFoldersResult()
        }

        Tool(
            name: "notes_tags",
            description:
                "List the tags (#hashtags) used in the Notes app, with how many notes carry each one, most used first. Counts come from database records, which may remain after a tag's text is deleted. Locked notes are skipped, and notes in Recently Deleted unless includeRecentlyDeleted is true.",
            inputSchema: .object(
                properties: [
                    "includeRecentlyDeleted": .boolean(
                        description: "Whether notes in Recently Deleted count",
                        default: false
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Tags",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.tagsResult(arguments)
        }

        Tool(
            name: "notes_read",
            description:
                "Read the full contents of a note from the Notes app, as Markdown with headings, lists, checklists, links, and tables, or as plain text, with its tags (keywords), the notes it links to (linkedNotes), and the notes that link to it (linkedFrom). Tags and links are database records, which may remain after their text is deleted; links set on ordinary text are not listed. Locked and Recently Deleted notes supply no tags or links but can be link targets. Attachments such as images and drawings appear as bracketed descriptions; notes_attachments lists them. Notes locked with a password can't be read.",
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
            let context = try await self.readContext(for: id)
            let (note, content) = (context.note, context.content)

            var object = note.properties(in: context.folders)
            object["@context"] = "https://schema.org"
            object["@type"] = "NoteDigitalDocument"
            object["encodingFormat"] = .string(isMarkdown ? "text/markdown" : "text/plain")
            object["text"] = .string(isMarkdown ? content.markdown() : content.plainText())
            object.merge(context.inlineProperties) { current, _ in current }
            object.merge(NoteTraits(content: content).properties) { current, _ in current }
            return object
        }

        Tool(
            name: "notes_attachments",
            description:
                "List the attachments of a note in the Notes app, such as images, drawings, tables, PDFs, and link cards, with each one's name, kind, type, and size in bytes. Returns what Notes records about them, not the files' contents. Notes locked with a password can't be read.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "The note @id, as returned by notes_fetch"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Attachments",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.attachmentsResult(arguments)
        }

        Tool(
            name: "notes_accounts",
            description:
                "List the accounts in the Notes app, such as iCloud and On My Mac, with how many folders and notes each holds. Notes in Recently Deleted are counted apart.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Accounts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.accountsResult()
        }

        Tool(
            name: "notes_stats",
            description:
                "Summarize the notes in the Notes app: how many there are in total, by account, pinned, locked, and in Recently Deleted, and when the oldest and newest were last edited. Reads note metadata only, so it is quick.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Summarize Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.statisticsResult()
        }
    }

    // MARK: - Tags, Links, and Smart Folders

    /// A note with its contents, tags, and links, read from one snapshot.
    private struct NoteContext: Sendable {
        var note: TopoText.Note
        var content: TopoText.Note.Content
        var folders: [TopoText.Folder]
        var tags: [TopoText.Note.Tag]
        var links: [TopoText.Note.Link]
        var backlinks: [TopoText.Note.Link]
        /// What lookups found of the notes at the other ends of the links, by identifier.
        var others: [TopoText.Note.ID: LinkedNote]

        /// The properties that a note's tags and links add to its object in tool output.
        var inlineProperties: [String: Value] {
            var object = note.inlineProperties(tags: tags, links: links, others: others)
            if !backlinks.isEmpty {
                object["linkedFrom"] = .array(
                    backlinks.map { linkValue($0, direction: .incoming, other: others[$0.sourceID] ?? .unknown) }
                )
            }
            return object
        }
    }

    private func readContext(for id: TopoText.Note.ID) async throws -> NoteContext {
        try checkDatabaseAccess()
        return try await withStore { store in
            try await store.withSnapshot { snapshot in
                let note = try snapshot.note(for: id)
                let content = try snapshot.content(for: id)
                let folders = try snapshot.folders()
                // A database that can't supply tags and links still gives the note without them.
                let tags = try readIfSupported { try snapshot.tags(for: [id]) }?[id] ?? []
                let links = try readIfSupported { try snapshot.links(from: [id]) }?[id] ?? []
                let backlinks = try readIfSupported { try snapshot.backlinks(to: id) } ?? []
                // The notes at the other ends of the links, for their titles, each looked up once.
                var others: [TopoText.Note.ID: LinkedNote] = [:]
                for other in links.map(\.targetID) + backlinks.map(\.sourceID) where others[other] == nil {
                    others[other] = try LinkedNote(lookingUp: { try snapshot.note(for: other).title })
                }
                return NoteContext(
                    note: note,
                    content: content,
                    folders: folders,
                    tags: tags,
                    links: links,
                    backlinks: backlinks,
                    others: others
                )
            }
        }
    }

    private func smartFoldersResult() async throws -> Value {
        try checkDatabaseAccess()
        let (smartFolders, folders): ([TopoText.SmartFolder], [TopoText.Folder]) = try await withStore { store in
            try await store.withSnapshot { snapshot in
                let smartFolders = try snapshot.smartFolders()
                let folders = try snapshot.folders()
                return (smartFolders, folders)
            }
        }
        let names = Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return .object([
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": "Smart Folders",
            "numberOfItems": .int(smartFolders.count),
            "itemListElement": .array(smartFolders.map { smartFolderValue($0, folderNames: names) }),
        ])
    }

    private func tagsResult(_ arguments: [String: Value]) async throws -> Value {
        let includesDeleted = try argument("includeRecentlyDeleted", in: arguments, as: \.boolValue) ?? false
        try checkDatabaseAccess()
        let summaries = try await withStore { try await $0.tags(includingRecentlyDeleted: includesDeleted) }
        let items: [Value] = summaries.map {
            .object(["name": .string($0.tag.text), "numberOfItems": .int($0.noteCount)])
        }
        return .object([
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": "Note Tags",
            "numberOfItems": .int(summaries.count),
            "itemListElement": .array(items),
        ])
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

    // MARK: - Tool Results

    private func attachmentsResult(_ arguments: [String: Value]) async throws -> Value {
        guard
            let argument = try self.argument("id", in: arguments, as: \.stringValue),
            let id = TopoText.Note.ID(argument.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw ArgumentError.invalid("id must be the @id of a note")
        }

        try self.checkDatabaseAccess()
        let attachments = try await self.withStore { store in
            try await store.withSnapshot { snapshot in
                let content = try snapshot.content(for: id)
                return attachmentValues(in: content) { attachment in
                    // A missing file is normal: Notes keeps some attachments only in iCloud.
                    guard let url = try? snapshot.fileURL(for: attachment.id) else { return nil }
                    return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                }
            }
        }

        return [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": "Note Attachments",
            "url": .string(noteURL(for: id)),
            "numberOfItems": .int(attachments.count),
            "itemListElement": .array(attachments),
        ]
    }

    private func accountsResult() async throws -> Value {
        try self.checkDatabaseAccess()
        let (accounts, folders) = try await self.withStore { store in
            try await store.withSnapshot { (try $0.accounts(), try $0.folders()) }
        }

        let items = accounts.map { account -> Value in
            let own = folders.filter { $0.account?.id == account.id }
            let live = own.filter { !$0.isRecentlyDeleted }
            var object: [String: Value] = [
                "@id": .string(account.id.description),
                "name": .string(account.name ?? "Unnamed Account"),
                "numberOfFolders": .int(live.count),
                "numberOfItems": .int(live.reduce(0) { $0 + $1.noteCount }),
            ]
            let deleted = own.filter(\.isRecentlyDeleted).reduce(0) { $0 + $1.noteCount }
            if deleted > 0 {
                object["numberOfRecentlyDeletedItems"] = .int(deleted)
            }
            return .object(object)
        }
        return [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": "Note Accounts",
            "numberOfItems": .int(items.count),
            "itemListElement": .array(items),
        ]
    }

    private func statisticsResult() async throws -> Value {
        try self.checkDatabaseAccess()
        let statistics = try await self.withStore { store in
            try await store.withSnapshot { snapshot in
                let folders = try snapshot.folders()
                var statistics = NoteStatistics()
                var request = TopoText.Note.FetchRequest(
                    includesRecentlyDeleted: true,
                    limit: TopoText.Note.FetchRequest.maximumLimit
                )
                for _ in 0 ..< NoteStatistics.pageLimit {
                    let result = try snapshot.search(request)
                    for note in result.notes {
                        let account = folders.first { $0.id == note.folderID }?.account
                        statistics.add(
                            isPinned: note.isPinned,
                            isLocked: note.isLocked,
                            isRecentlyDeleted: note.isRecentlyDeleted,
                            account: account?.name ?? account?.id.description,
                            modificationDate: note.modificationDate
                        )
                    }
                    guard let next = result.nextCursor else { return statistics }
                    request.cursor = next
                }
                statistics.isTruncated = true
                return statistics
            }
        }
        return statistics.value
    }

    // MARK: - Arguments and Search

    /// The most notes whose contents one `notes_fetch` call reads to apply a filter,
    /// which bounds the time of a call whose filters match few notes.
    private static let contentReadLimit = 500
    /// The most notes one `notes_fetch` call scans to apply metadata filters,
    /// bounding large stores. The budget counts every note the search examined,
    /// including notes that matched no text query.
    private static let metadataScanLimit = 2_000

    /// One page of notes, after the filters that TopoText can't apply.
    private struct NotesPage: Sendable {
        enum StoppedEarly: Sendable {
            case contentRead
            case metadataScan
        }

        var notes: [TopoText.Note] = []
        var nextCursor: TopoText.Note.FetchRequest.Cursor?
        var unreadableNoteIDs: [TopoText.Note.ID] = []
        /// What the contents of each note hold, for the notes whose contents were read.
        var traits: [TopoText.Note.ID: NoteTraits] = [:]
        /// Whether the search hit a scan limit before filling the page.
        var stoppedEarly: StoppedEarly?
    }

    /// Searches the notes, then keeps those that pass the filter.
    ///
    /// `FetchRequest` filters by text, folder, and modification date only,
    /// so this asks for as many notes as the page still needs and filters them,
    /// until the page is full or the notes run out.
    /// Every page it asks for is examined to its end, so `nextCursor` skips no note.
    /// The scan budget counts the notes the search examined, not the notes it
    /// returned, so a text query with few matches cannot scan far past it.
    private static func search(
        _ request: TopoText.Note.FetchRequest,
        filter: NoteFilter,
        scanLimit: Int = metadataScanLimit,
        in snapshot: TopoText.Store.Snapshot
    ) throws -> NotesPage {
        let wanted = request.limit
        var request = request
        var page = NotesPage()
        var read = 0
        var scanned = 0
        while page.notes.count < wanted {
            let remaining = scanLimit - scanned
            guard remaining > 0 else {
                page.stoppedEarly = .metadataScan
                break
            }
            // Cap the page by what is left of the scan budget.
            request.limit = min(wanted - page.notes.count, remaining)
            let result = try snapshot.search(request)
            scanned += result.scannedNoteCount
            // Unreadable notes are reported whether or not they matched.
            for id in result.unreadableNoteIDs where !page.unreadableNoteIDs.contains(id) {
                page.unreadableNoteIDs.append(id)
            }
            // Tags come from the same records the note's `keywords` come from.
            let ids = result.notes.map(\.id)
            let tags =
                filter.needsTags
                ? (try readIfSupported { try snapshot.tags(for: ids) } ?? [:]) : [:]
            for note in result.notes {
                guard
                    filter.matches(
                        isPinned: note.isPinned,
                        isLocked: note.isLocked,
                        creationDate: note.creationDate
                    )
                else { continue }
                guard filter.matches(tags: tags[note.id] ?? []) else { continue }
                guard filter.needsContents else {
                    page.notes.append(note)
                    if result.unreadableNoteIDs.contains(note.id) {
                        page.unreadableNoteIDs.append(note.id)
                    }
                    continue
                }
                read += 1
                do {
                    let traits = NoteTraits(content: try snapshot.content(for: note.id))
                    guard filter.matches(traits) else { continue }
                    page.traits[note.id] = traits
                    page.notes.append(note)
                } catch is TopoText.NotesError {
                    // A locked note or a damaged one can't be checked against the filter.
                    page.unreadableNoteIDs.append(note.id)
                }
            }
            page.nextCursor = result.nextCursor
            guard result.nextCursor != nil else { break }
            request.cursor = result.nextCursor
            if page.notes.count < wanted {
                if read >= contentReadLimit {
                    page.stoppedEarly = .contentRead
                    break
                }
                if scanned >= scanLimit {
                    page.stoppedEarly = .metadataScan
                    break
                }
            }
        }
        return page
    }

    /// Returns a date argument as a start or end of a range.
    private func dateArgument(_ name: String, in arguments: [String: Value], isEnd: Bool) throws -> Date? {
        guard let string = try argument(name, in: arguments, as: \.stringValue) else { return nil }
        guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: string) else {
            throw ArgumentError.invalid("\(name) must be an ISO 8601 date")
        }
        return isEnd
            ? Calendar.current.normalizedEndDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
            : Calendar.current.normalizedStartDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
    }

    private func noteFilter(from arguments: [String: Value]) throws -> NoteFilter {
        var filter = NoteFilter()
        if let tags = try argument("tag", in: arguments, as: \.arrayValue) {
            filter.tags = try tags.map {
                guard let tag = $0.stringValue.flatMap(NoteFilter.normalizedTag) else {
                    throw ArgumentError.invalid("tag must be a list of tag names")
                }
                return tag
            }
        }
        if let features = try argument("has", in: arguments, as: \.arrayValue) {
            filter.features = Set(
                try features.map {
                    guard let feature = $0.stringValue.flatMap(NoteFeature.init(rawValue:)) else {
                        throw ArgumentError.invalid(
                            "has must be a list of: \(NoteFeature.allCases.map(\.rawValue).joined(separator: ", "))"
                        )
                    }
                    return feature
                }
            )
        }
        filter.isPinned = try argument("pinned", in: arguments, as: \.boolValue)
        filter.isLocked = try argument("locked", in: arguments, as: \.boolValue)
        filter.minimumWords = try argument("minWords", in: arguments, as: \.intValue)
        filter.maximumWords = try argument("maxWords", in: arguments, as: \.intValue)
        if let minimum = filter.minimumWords, let maximum = filter.maximumWords, minimum > maximum {
            throw ArgumentError.invalid("minWords must not be more than maxWords")
        }
        if filter.minimumWords.map({ $0 < 0 }) ?? false || filter.maximumWords.map({ $0 < 0 }) ?? false {
            throw ArgumentError.invalid("minWords and maxWords must not be negative")
        }
        filter.createdStart = try dateArgument("createdStart", in: arguments, isEnd: false)
        filter.createdEnd = try dateArgument("createdEnd", in: arguments, isEnd: true)
        if let start = filter.createdStart, let end = filter.createdEnd, start >= end {
            throw ArgumentError.invalid("createdStart must be before createdEnd")
        }
        return filter
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
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // A stale bookmark still resolves, but it must be recreated and stored again.
            // If that fails, this resolution still works, so keep it and retry next time.
            log.debug("Renewing the stale Notes folder bookmark")
            do {
                try withSecurityScopedAccess(url, storeBookmark)
            } catch {
                log.error("Failed to renew the Notes folder bookmark: \(error.localizedDescription)")
            }
        }
        return url
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    /// Runs an operation on the store inside the grant for the bookmarked folder,
    /// or for the database at the default path when nothing is bookmarked.
    ///
    /// The bookmark comes first whenever one exists: while another call holds the grant,
    /// the default path is readable too, but it stops being readable when that call ends,
    /// so each call holds a grant of its own.
    /// A bookmark that no longer resolves grants nothing, so no call can hold its grant;
    /// if the default path is readable then, as with Full Disk Access, it's used instead.
    /// Errors from TopoText are rethrown as `StoreError`, which describes them for the client.
    private func withStore<T>(_ operation: (TopoText.Store) async throws -> T) async throws -> T {
        do {
            guard UserDefaults.standard.data(forKey: notesContainerBookmarkKey) != nil else {
                return try await operation(TopoText.Store(root: notesContainerURL))
            }

            let directory: URL
            do {
                directory = try resolveBookmarkedContainer()
            } catch let error where canAccessDatabaseAtDefaultPath {
                log.error(
                    "Using the Notes database at the default path because the stored bookmark doesn't resolve: \(error.localizedDescription)"
                )
                return try await operation(TopoText.Store(root: notesContainerURL))
            }

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
            To read your notes, iMCP needs access to the folder where the Notes app keeps them: \
            the database and the log that recent edits are written to first.

            Next, select the `group.com.apple.notes` folder and click "Grant Access".
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
        if parentID != nil,
            let path = folderPath(
                of: id,
                in: folders.map { FolderNode(id: $0.id, name: $0.name, parentID: $0.parentID) }
            )
        {
            // The path tells nested folders with the same name apart.
            object["path"] = .string(path)
        }
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
    fileprivate func properties(
        in folders: [TopoText.Folder],
        tags: [TopoText.Note.ID: [TopoText.Note.Tag]],
        links: [TopoText.Note.ID: [TopoText.Note.Link]]
    ) -> [String: Value] {
        var object = properties(in: folders)
        object.merge(inlineProperties(tags: tags[id] ?? [], links: links[id] ?? [], others: [:])) { $1 }
        return object
    }

    /// The note's metadata as the properties of a JSON object for tool output.
    fileprivate func properties(in folders: [TopoText.Folder]) -> [String: Value] {
        var object: [String: Value] = [
            "@id": .string(id.description),
            "name": .string(title.isEmpty ? "New Note" : title),
            "url": .string(noteURL(for: id)),
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
        if isRecentlyDeleted {
            object["isRecentlyDeleted"] = true
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

extension TopoText.Note {
    /// A note's tags and links to other notes as properties of a JSON object for tool output.
    /// - Parameter others: What lookups found of the notes at the other ends of the links, by identifier;
    ///   a note that isn't in it is unknown.
    fileprivate func inlineProperties(
        tags: [TopoText.Note.Tag],
        links: [TopoText.Note.Link],
        others: [TopoText.Note.ID: LinkedNote]
    ) -> [String: Value] {
        var object: [String: Value] = [:]
        if !tags.isEmpty {
            object["keywords"] = keywordValues(tags)
        }
        if !links.isEmpty {
            object["linkedNotes"] = .array(
                links.map { linkValue($0, direction: .outgoing, other: others[$0.targetID] ?? .unknown) }
            )
        }
        return object
    }
}
