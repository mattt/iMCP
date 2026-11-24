import Foundation
import TopoText

// This file holds the parts of the Notes service that don't need a database:
// what a note's contents hold, the filters built on that, and the output shapes.
// TopoText builds notes and folders only from a database,
// so these functions take their plain values (`Note.Content`, a folder's name and parent) instead.

/// Something that a note's contents can hold, for the `has` filter of `notes_fetch`.
enum NoteFeature: String, CaseIterable, Sendable {
    /// Any object other than a tag, mention, note link, or calculation result:
    /// an image, a table, a drawing, a file, or a link card.
    case attachment
    case checklist
    case table
    /// A link in the text or a link card for a web page.
    case link
    case drawing
    case image
    case pdf
    case audio
    case video
    /// A scanned document.
    case scan
}

/// What a note's contents hold, found by reading its paragraphs once.
struct NoteTraits: Sendable, Hashable {
    /// The tags in the note, as `#name` in the order they first appear, without repeats.
    var tags: [String] = []
    var features: Set<NoteFeature> = []
    var wordCount = 0
    /// The web addresses in the note's text and link cards, without repeats.
    var links: [String] = []

    init(content: TopoText.Note.Content) {
        var seenTags: Set<String> = []
        var seenLinks: Set<String> = []
        for paragraph in content.paragraphs {
            if paragraph.style.kind == .checklist {
                features.insert(.checklist)
            }
            var text = ""
            for run in paragraph.runs {
                if let link = run.link, seenLinks.insert(link).inserted {
                    links.append(link)
                    features.insert(.link)
                }
                guard let attachment = run.attachment else {
                    text += run.text
                    continue
                }
                // The run's text is the object replacement character, which is not a word.
                text += " "
                record(attachment, tags: &seenTags, links: &seenLinks)
            }
            wordCount += text.split(whereSeparator: \.isWhitespace).count
        }
    }

    private mutating func record(
        _ attachment: TopoText.Note.Attachment,
        tags seenTags: inout Set<String>,
        links seenLinks: inout Set<String>
    ) {
        let kind = attachment.kind
        if !kind.isInline {
            features.insert(.attachment)
        }
        switch kind {
        case .hashtag:
            if let tag = attachment.displayText.flatMap(NoteFilter.normalizedTag),
                seenTags.insert(tag.lowercased()).inserted
            {
                tags.append("#" + tag)
            }
        case .table: features.insert(.table)
        case .webLink:
            features.insert(.link)
            if let url = attachment.url?.absoluteString, seenLinks.insert(url).inserted {
                links.append(url)
            }
        case .drawing: features.insert(.drawing)
        case .image: features.insert(.image)
        case .pdf: features.insert(.pdf)
        case .audio: features.insert(.audio)
        case .video: features.insert(.video)
        case .scannedDocument: features.insert(.scan)
        case .mention, .noteLink, .calculation, .inlineText, .contact, .file: break
        }
    }
}

/// Filters for notes that Notes can't apply itself,
/// because they depend on what a note holds or on flags that `FetchRequest` has no field for.
///
/// Like the fields of `FetchRequest`, the filters combine with AND.
struct NoteFilter: Sendable, Equatable {
    /// Tags that every result must have, without the leading `#`.
    var tags: [String] = []
    var features: Set<NoteFeature> = []
    var isPinned: Bool?
    var isLocked: Bool?
    var minimumWords: Int?
    var maximumWords: Int?
    var createdStart: Date?
    var createdEnd: Date?

    /// Whether a note's contents have to be read to apply the filter.
    /// Tags come from the database's tag records, so a tag filter does not
    /// need the note's text.
    var needsContents: Bool {
        !features.isEmpty || minimumWords != nil || maximumWords != nil
    }

    /// Whether the filter reads the database's tag records.
    var needsTags: Bool { !tags.isEmpty }

    var isEmpty: Bool {
        !needsContents && !needsTags && isPinned == nil && isLocked == nil
            && createdStart == nil && createdEnd == nil
    }

    /// Returns a tag as Notes compares it: without `#` or surrounding white space.
    /// - Returns: `nil` if nothing remains.
    static func normalizedTag(_ tag: String) -> String? {
        var tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") {
            tag.removeFirst()
        }
        return tag.isEmpty ? nil : tag
    }

    /// Whether a note's flags and dates pass the filter, before its contents are read.
    func matches(isPinned: Bool, isLocked: Bool, creationDate: Date?) -> Bool {
        if let wanted = self.isPinned, wanted != isPinned { return false }
        if let wanted = self.isLocked, wanted != isLocked { return false }
        // A note without a creation date can't be placed in a range.
        if createdStart != nil || createdEnd != nil {
            guard let creationDate else { return false }
            if let createdStart, creationDate < createdStart { return false }
            if let createdEnd, creationDate >= createdEnd { return false }
        }
        return true
    }

    /// Whether the note's tag records pass the tag filter.
    ///
    /// The records are the same ones the note's `keywords` come from, so a
    /// tag filter matches what the output shows.
    func matches(tags: [TopoText.Note.Tag]) -> Bool {
        guard !self.tags.isEmpty else { return true }
        let present = Set(
            tags.map(\.text).compactMap(Self.normalizedTag).map { $0.lowercased() }
        )
        return self.tags.allSatisfy { tag in
            Self.normalizedTag(tag).map { present.contains($0.lowercased()) } ?? false
        }
    }

    /// Whether a note's contents pass the content filters.
    func matches(_ traits: NoteTraits) -> Bool {
        if !features.isSubset(of: traits.features) { return false }
        if let minimumWords, traits.wordCount < minimumWords { return false }
        if let maximumWords, traits.wordCount > maximumWords { return false }
        return true
    }
}

// MARK: - Output

extension TopoText.Note.Attachment.Kind {
    /// The name of the kind in tool output.
    var label: String {
        switch self {
        case .hashtag: return "tag"
        case .mention: return "mention"
        case .noteLink: return "noteLink"
        case .calculation: return "calculation"
        case .inlineText: return "inlineText"
        case .table: return "table"
        case .webLink: return "webLink"
        case .drawing: return "drawing"
        case .scannedDocument: return "scannedDocument"
        case .image: return "image"
        case .pdf: return "pdf"
        case .audio: return "audio"
        case .video: return "video"
        case .contact: return "contact"
        case .file: return "file"
        }
    }
}

extension NoteTraits {
    /// The traits as properties of a note in tool output.
    ///
    /// Tags are not here: a note's `keywords` come from the database's tag
    /// records, which are the same records the tag filter reads.
    var properties: [String: Value] {
        var object: [String: Value] = ["wordCount": .int(wordCount)]
        if !features.isEmpty {
            object["has"] = .array(features.map(\.rawValue).sorted().map { .string($0) })
        }
        if !links.isEmpty {
            object["links"] = .array(links.map { .string($0) })
        }
        return object
    }
}

/// The link that opens a note in the Notes app.
func noteURL(for id: TopoText.Note.ID) -> String {
    "notes://showNote?identifier=\(id.description)"
}

/// The attachments of a note, as objects of the note's `hasPart` property,
/// with what Notes records about each attachment but not the file's contents.
///
/// Tags, mentions, links to notes, and calculation results are text within a line
/// and are left out; a tag is in the note's `keywords`.
/// - Parameters:
///   - content: The contents of the note.
///   - fileSize: Returns the size in bytes of the file that holds an attachment, or `nil` if it has none.
func attachmentValues(
    in content: TopoText.Note.Content,
    fileSize: (TopoText.Note.Attachment) -> Int?
) -> [Value] {
    var seen: Set<TopoText.Note.Attachment.ID> = []
    var values: [Value] = []
    for paragraph in content.paragraphs {
        for attachment in paragraph.runs.compactMap(\.attachment) {
            let kind = attachment.kind
            guard !kind.isInline, seen.insert(attachment.id).inserted else { continue }
            var object: [String: Value] = [
                "@id": .string(attachment.id.description),
                "@type": "MediaObject",
                "kind": .string(kind.label),
            ]
            if let name = attachment.fileName ?? attachment.title {
                object["name"] = .string(name)
            }
            if let type = attachment.typeIdentifier {
                object["encodingFormat"] = .string(type)
            }
            if let url = attachment.url {
                object["url"] = .string(url.absoluteString)
            }
            if let size = fileSize(attachment) {
                object["contentSize"] = .int(size)
            }
            values.append(.object(object))
        }
    }
    return values
}

/// A folder's place in the folder tree, for `folderPath(of:in:)`.
struct FolderNode: Sendable, Hashable {
    var id: TopoText.Folder.ID
    var name: String
    var parentID: TopoText.Folder.ID?
    var accountName: String?
}

/// Returns the names from the outermost folder to the folder, joined with `/`.
///
/// A folder whose parent is not in the list, or whose parents form a loop, is the start of the path.
func folderPath(of id: TopoText.Folder.ID, in folders: [FolderNode]) -> String? {
    let nodes = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard var node = nodes[id] else { return nil }
    var names = [node.name]
    var visited: Set<TopoText.Folder.ID> = [id]
    while let parentID = node.parentID, let parent = nodes[parentID], visited.insert(parentID).inserted {
        names.append(parent.name)
        node = parent
    }
    return names.reversed().joined(separator: "/")
}

/// Counts of notes, for `notes_stats`.
struct NoteStatistics: Sendable, Equatable {
    /// The most pages of notes that a summary reads, 100 notes each, so a huge library can't stall a call.
    static let pageLimit = 100

    private(set) var total = 0
    private(set) var pinned = 0
    private(set) var locked = 0
    private(set) var recentlyDeleted = 0
    private(set) var oldestModification: Date?
    private(set) var newestModification: Date?
    private var byAccount: [String: Int] = [:]
    /// Whether the summary stopped before the last note.
    var isTruncated = false

    /// Adds a note. Notes in Recently Deleted count toward `recentlyDeleted` only.
    mutating func add(
        isPinned: Bool,
        isLocked: Bool,
        isRecentlyDeleted: Bool,
        account: String?,
        modificationDate: Date?
    ) {
        if isRecentlyDeleted {
            recentlyDeleted += 1
            return
        }
        total += 1
        if isPinned { pinned += 1 }
        if isLocked { locked += 1 }
        byAccount[account ?? "Unknown", default: 0] += 1
        if let modificationDate {
            oldestModification = min(oldestModification ?? modificationDate, modificationDate)
            newestModification = max(newestModification ?? modificationDate, modificationDate)
        }
    }

    var value: Value {
        var object: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "Dataset",
            "name": "Notes Statistics",
            "numberOfItems": .int(total),
            "numberOfPinnedItems": .int(pinned),
            "numberOfLockedItems": .int(locked),
            "numberOfRecentlyDeletedItems": .int(recentlyDeleted),
            "numberOfItemsByAccount": .object(byAccount.mapValues { .int($0) }),
        ]
        if let oldestModification {
            object["oldestDateModified"] = .string(oldestModification.formatted(.iso8601))
        }
        if let newestModification {
            object["newestDateModified"] = .string(newestModification.formatted(.iso8601))
        }
        if isTruncated {
            object["description"] = .string(
                "The summary stopped after \(Self.pageLimit * 100) notes, so a larger library has more than it counts."
            )
        }
        return .object(object)
    }
}

// MARK: - Search

/// The notes in a search result that the filters read.
protocol FilterableNote: Sendable {
    var id: TopoText.Note.ID { get }
    var isPinned: Bool { get }
    var isLocked: Bool { get }
    var creationDate: Date? { get }
}

extension TopoText.Note: FilterableNote {}

/// One page of a search, as `Store.SearchResult` reports it.
struct SearchPage<Note: FilterableNote>: Sendable {
    var notes: [Note]
    var nextCursor: TopoText.Note.FetchRequest.Cursor?
    var scannedNoteCount: Int
    var unreadableNoteIDs: [TopoText.Note.ID]
}

/// What `searchNotes` reads from the database, so that tests can stand in for it.
protocol NoteSearchSource {
    associatedtype Note: FilterableNote
    func search(_ request: TopoText.Note.FetchRequest) throws -> SearchPage<Note>
    /// Returns `nil` if the database can't supply tags.
    func tags(for ids: [TopoText.Note.ID]) throws -> [TopoText.Note.ID: [TopoText.Note.Tag]]?
    func content(for id: TopoText.Note.ID) throws -> TopoText.Note.Content
}

/// A snapshot of the Notes database as a source of notes.
struct SnapshotNoteSource: NoteSearchSource {
    let snapshot: TopoText.Store.Snapshot

    func search(_ request: TopoText.Note.FetchRequest) throws -> SearchPage<TopoText.Note> {
        let result = try snapshot.search(request)
        return SearchPage(
            notes: result.notes,
            nextCursor: result.nextCursor,
            scannedNoteCount: result.scannedNoteCount,
            unreadableNoteIDs: result.unreadableNoteIDs
        )
    }

    func tags(for ids: [TopoText.Note.ID]) throws -> [TopoText.Note.ID: [TopoText.Note.Tag]]? {
        try readIfSupported { try snapshot.tags(for: ids) }
    }

    func content(for id: TopoText.Note.ID) throws -> TopoText.Note.Content {
        try snapshot.content(for: id)
    }
}

/// A tag filter was requested, but the database can't supply tag records.
struct NoteTagsUnavailableError: LocalizedError {
    var errorDescription: String? {
        "This Notes database can't supply tags, so the tag filter can't be applied. Remove the tag filter and try again."
    }
}

/// One page of notes, after the filters that TopoText can't apply.
struct NotesPage<Note: FilterableNote>: Sendable {
    enum StoppedEarly: Sendable {
        case contentRead
        case metadataScan
    }

    var notes: [Note] = []
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
/// returned. Each request's `limit` and `scanLimit` are capped by what is left
/// of the budget, so a text query with few matches cannot scan past it.
func searchNotes<Source: NoteSearchSource>(
    _ request: TopoText.Note.FetchRequest,
    filter: NoteFilter,
    scanLimit: Int,
    contentReadLimit: Int,
    in source: Source
) throws -> NotesPage<Source.Note> {
    let wanted = request.limit
    var request = request
    var page = NotesPage<Source.Note>()
    var read = 0
    var scanned = 0
    func noteUnreadable(_ id: TopoText.Note.ID) {
        if !page.unreadableNoteIDs.contains(id) { page.unreadableNoteIDs.append(id) }
    }
    while page.notes.count < wanted {
        let remaining = scanLimit - scanned
        guard remaining > 0 else {
            page.stoppedEarly = .metadataScan
            break
        }
        // Cap the page and the notes examined by what is left of the scan budget.
        request.limit = min(wanted - page.notes.count, remaining)
        request.scanLimit = min(request.scanLimit, remaining)
        let result = try source.search(request)
        scanned += result.scannedNoteCount
        // Unreadable notes are reported whether or not they matched.
        result.unreadableNoteIDs.forEach(noteUnreadable)
        // Tags come from the same records the note's `keywords` come from.
        var tags: [TopoText.Note.ID: [TopoText.Note.Tag]] = [:]
        if filter.needsTags {
            guard let found = try source.tags(for: result.notes.map(\.id)) else {
                throw NoteTagsUnavailableError()
            }
            tags = found
        }
        for note in result.notes {
            guard
                filter.matches(isPinned: note.isPinned, isLocked: note.isLocked, creationDate: note.creationDate)
            else { continue }
            guard filter.matches(tags: tags[note.id] ?? []) else { continue }
            guard filter.needsContents else {
                page.notes.append(note)
                continue
            }
            read += 1
            do {
                let traits = NoteTraits(content: try source.content(for: note.id))
                guard filter.matches(traits) else { continue }
                page.traits[note.id] = traits
                page.notes.append(note)
            } catch is TopoText.NotesError {
                // A locked note or a damaged one can't be checked against the filter.
                noteUnreadable(note.id)
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

// MARK: - Finding what a script created

/// The folders at `path` (names from the outermost folder) in the account, for finding a folder
/// that the Notes scripting interface made. An empty path names the account's default folder,
/// which is the top-level folder called `defaultFolderName`.
func folderIDs(
    atPath path: [String],
    defaultFolderName: String,
    accountName: String,
    among folders: [FolderNode]
) -> [TopoText.Folder.ID] {
    folders.filter { node in
        guard node.accountName == accountName else { return false }
        if path.isEmpty { return node.name == defaultFolderName && node.parentID == nil }
        return folderPath(of: node.id, in: folders) == path.joined(separator: "/")
    }.map(\.id)
}

/// A note in the database, for finding the one that a script created.
struct NoteCandidate: Sendable, Equatable {
    var id: TopoText.Note.ID
    var title: String
    var creationDate: Date?
}

/// Returns the identifier of the one note with exactly this title that was created at or after `date`,
/// or `nil` if there is none or more than one, so a guess never names the wrong note.
func uniqueNewNoteID(title: String, createdAfter date: Date, among candidates: [NoteCandidate]) -> TopoText.Note.ID? {
    let matches = candidates.filter { candidate in
        candidate.title == title && (candidate.creationDate.map { $0 >= date } ?? false)
    }
    return matches.count == 1 ? matches[0].id : nil
}
