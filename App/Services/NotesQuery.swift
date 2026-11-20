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
