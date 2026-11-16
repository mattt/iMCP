import Foundation

// Safari bookmarks, from the file that Safari's own File > Export > Bookmarks writes.
//
// Safari has no scripting or framework interface for bookmarks,
// and iMCP's sandbox can't read the property list that Safari keeps them in.
// The export is Safari's supported way to hand bookmarks to another program:
// a Netscape bookmark file, which is HTML.
// This file reads it. It needs no Safari, so tests can cover it.

/// A bookmark in an exported file.
struct SafariBookmark: Equatable, Sendable {
    let title: String
    let url: String
    /// The folders that hold the bookmark, outermost first. Empty at the top level.
    let folders: [String]
    /// When the bookmark was added, if the file says.
    let addedDate: Date?

    var folderPath: String { folders.joined(separator: "/") }
}

/// The bookmarks of an exported file.
struct SafariBookmarksSnapshot: Equatable, Sendable {
    let bookmarks: [SafariBookmark]
    /// The folders that hold at least one bookmark or folder, as paths such as `Favorites/News`.
    let folderPaths: [String]
}

enum SafariBookmarksFile {
    /// The largest file that is read. A file of bookmarks is far smaller.
    static let maximumBytes = 50_000_000

    /// Reads a Netscape bookmark file, which is what Safari exports.
    ///
    /// The reader is forgiving about what real files do:
    /// tags in either case, quoted or bare attributes, and missing closing tags.
    /// A link without an address is skipped.
    static func parse(_ data: Data) -> SafariBookmarksSnapshot {
        let bytes = [UInt8](data)
        var bookmarks: [SafariBookmark] = []
        var folderPaths: [String] = []
        var seenFolders = Set<String>()

        // One entry for each open <DL>: the name of the folder it lists, or nil for the outermost list.
        var stack: [String?] = []
        var pendingFolder: String?
        var openLink: (attributes: [String: String], start: Int)?
        var openHeading: Int?

        func currentFolders() -> [String] { stack.compactMap { $0 } }

        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            // A tag runs to the next ">" that isn't inside quotes.
            var end = index + 1
            var quote: UInt8?
            while end < bytes.count {
                let byte = bytes[end]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    break
                }
                end += 1
            }
            guard end < bytes.count else { break }

            let tag = String(decoding: bytes[(index + 1) ..< end], as: UTF8.self)
            let (name, attributes) = parseTag(tag)
            let textStart = end + 1

            switch name {
            case "dl":
                stack.append(pendingFolder)
                if pendingFolder != nil {
                    let path = currentFolders().joined(separator: "/")
                    if seenFolders.insert(path).inserted { folderPaths.append(path) }
                }
                pendingFolder = nil
            case "/dl":
                if !stack.isEmpty { stack.removeLast() }
            case "h3", "h1":
                openHeading = textStart
            case "/h3", "/h1":
                if let start = openHeading, name == "/h3" {
                    let title = decodeText(bytes[start ..< index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingFolder = title.isEmpty ? "Untitled" : title
                }
                openHeading = nil
            case "a":
                openLink = (attributes, textStart)
            case "/a":
                if let link = openLink {
                    openLink = nil
                    if let url = link.attributes["href"].map(decodeEntities)?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                        !url.isEmpty
                    {
                        let title = decodeText(bytes[link.start ..< index]).trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        bookmarks.append(
                            SafariBookmark(
                                title: title.isEmpty ? url : title,
                                url: url,
                                folders: currentFolders(),
                                addedDate: link.attributes["add_date"].flatMap(date(fromEpoch:))
                            )
                        )
                    }
                }
            default:
                break
            }
            index = end + 1
        }

        return SafariBookmarksSnapshot(bookmarks: bookmarks, folderPaths: folderPaths)
    }

    // MARK: - Tags and text

    /// Splits `A HREF="x" ADD_DATE=1` into its lowercased name and attributes.
    static func parseTag(_ tag: String) -> (name: String, attributes: [String: String]) {
        let scalars = Array(tag.unicodeScalars)
        var position = 0

        func skipSpaces() {
            while position < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[position]) {
                position += 1
            }
        }

        var name = ""
        while position < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[position]) {
            name.unicodeScalars.append(scalars[position])
            position += 1
        }

        var attributes: [String: String] = [:]
        while true {
            skipSpaces()
            guard position < scalars.count else { break }
            var key = ""
            while position < scalars.count, scalars[position] != "=",
                !CharacterSet.whitespacesAndNewlines.contains(scalars[position])
            {
                key.unicodeScalars.append(scalars[position])
                position += 1
            }
            skipSpaces()
            var value = ""
            if position < scalars.count, scalars[position] == "=" {
                position += 1
                skipSpaces()
                if position < scalars.count, scalars[position] == "\"" || scalars[position] == "'" {
                    let quote = scalars[position]
                    position += 1
                    while position < scalars.count, scalars[position] != quote {
                        value.unicodeScalars.append(scalars[position])
                        position += 1
                    }
                    position += 1
                } else {
                    while position < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[position]) {
                        value.unicodeScalars.append(scalars[position])
                        position += 1
                    }
                }
            }
            if !key.isEmpty { attributes[key.lowercased()] = value }
        }
        return (name.lowercased(), attributes)
    }

    /// The text between two tags, without any markup inside it.
    private static func decodeText(_ bytes: ArraySlice<UInt8>) -> String {
        var plain: [UInt8] = []
        var insideTag = false
        for byte in bytes {
            if byte == UInt8(ascii: "<") {
                insideTag = true
            } else if byte == UInt8(ascii: ">") {
                insideTag = false
            } else if !insideTag {
                plain.append(byte)
            }
        }
        return decodeEntities(String(decoding: plain, as: UTF8.self))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    /// Replaces `&amp;`, `&#39;`, `&#x27;`, and the other common entities.
    /// An entity that isn't recognized is left as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var remaining = Substring(text)
        while let ampersand = remaining.firstIndex(of: "&") {
            result += remaining[remaining.startIndex ..< ampersand]
            let rest = remaining[remaining.index(after: ampersand)...]
            if let semicolon = rest.prefix(10).firstIndex(of: ";") {
                let entity = String(rest[rest.startIndex ..< semicolon])
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst(1)).flatMap(Unicode.Scalar.init).map(String.init)
                } else {
                    replacement = namedEntities[entity.lowercased()]
                }
                if let replacement {
                    result += replacement
                    remaining = rest[rest.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            remaining = rest
        }
        result += remaining
        return result
    }

    /// A date from seconds since 1970, as the file writes `ADD_DATE`.
    static func date(fromEpoch text: String) -> Date? {
        guard let seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A search of a snapshot.
struct SafariBookmarkQuery: Equatable, Sendable {
    static let defaultLimit = 50
    static let maximumLimit = 200

    var text: String?
    /// A folder path such as `Favorites` or `Favorites/News`. Bookmarks in its subfolders match too.
    var folder: String?
    var addedAfter: Date?
    var addedBefore: Date?
    var limit = defaultLimit
    var offset = 0

    /// Checks the paging arguments.
    func validated() throws -> SafariBookmarkQuery {
        guard (1 ... Self.maximumLimit).contains(limit) else {
            throw SafariError.invalid("limit must be from 1 to \(Self.maximumLimit)")
        }
        guard offset >= 0 else { throw SafariError.invalid("offset can't be negative") }
        if let addedAfter, let addedBefore, addedAfter >= addedBefore {
            throw SafariError.invalid("addedAfter must be earlier than addedBefore")
        }
        return self
    }

    /// The bookmarks that match, in the order of the file, and the number that matched before paging.
    func run(on snapshot: SafariBookmarksSnapshot) -> (page: [SafariBookmark], total: Int) {
        let words = (text ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let folderPath = folder?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()

        let matches = snapshot.bookmarks.filter { bookmark in
            if !words.isEmpty {
                let haystack = "\(bookmark.title)\n\(bookmark.url)\n\(bookmark.folderPath)".lowercased()
                guard words.allSatisfy({ haystack.contains($0) }) else { return false }
            }
            if let folderPath, !folderPath.isEmpty {
                let path = bookmark.folderPath.lowercased()
                guard path == folderPath || path.hasPrefix(folderPath + "/") else { return false }
            }
            if addedAfter != nil || addedBefore != nil {
                guard let added = bookmark.addedDate else { return false }
                if let addedAfter, added < addedAfter { return false }
                if let addedBefore, added >= addedBefore { return false }
            }
            return true
        }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        return (page, matches.count)
    }
}
