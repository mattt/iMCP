import Foundation

// Turning the HTML that the Notes app reports for a note into Markdown, JSON, and a standalone HTML page.
//
// This is iMCP's own converter, for the HTML that Notes' scripting interface returns:
// `div`, `h1` to `h3`, `b`, `i`, `u`, `strike`, `tt`, `a`, `ul`, `ol`, `li`, `table`, `br`, `img`, and `span`.
// It keeps what Markdown can say, and drops styling that it can't, such as colors and fonts.
// It needs no Notes app, so that tests can cover it.

enum NotesHTMLToMarkdown {
    static func markdown(fromHTML html: String) -> String {
        var converter = Converter()
        converter.run(html)
        return converter.result()
    }

    // MARK: - Converter

    private struct Converter {
        var lines: [String] = []
        var current = ""
        /// The Markdown that starts the line being built: a heading's hashes or a list item's bullet.
        var linePrefix = ""
        var lists: [(ordered: Bool, counter: Int)] = []
        var anchors: [(start: String.Index?, href: String, outputLength: Int)] = []
        var skipDepth = 0
        var table: [[String]] = []
        var row: [String]?
        var inCell = false
        var inQuote = 0

        mutating func run(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<" {
                    if html[index...].hasPrefix("<!--") {
                        if let end = html.range(of: "-->", range: index ..< html.endIndex) {
                            index = end.upperBound
                        } else {
                            index = html.endIndex
                        }
                        continue
                    }
                    guard let end = Self.tagEnd(in: html, from: index) else {
                        text("<")
                        index = html.index(after: index)
                        continue
                    }
                    tag(String(html[html.index(after: index) ..< end]))
                    index = html.index(after: end)
                } else {
                    var next = index
                    while next < html.endIndex, html[next] != "<" { next = html.index(after: next) }
                    text(Self.decode(String(html[index ..< next])))
                    index = next
                }
            }
            flush()
        }

        /// The index of the `>` that ends the tag that starts at `start`, skipping quoted attribute values.
        private static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
            var quote: Character?
            var index = html.index(after: start)
            while index < html.endIndex {
                let character = html[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    return index
                }
                index = html.index(after: index)
            }
            return nil
        }

        mutating func text(_ value: String) {
            guard skipDepth == 0 else { return }
            // Source line breaks and runs of spaces are one space in HTML.
            var collapsed = ""
            var lastWasSpace = current.last == " " || current.isEmpty
            for character in value {
                if character == "\n" || character == "\r" || character == "\t" || character == " " {
                    if !lastWasSpace { collapsed.append(" ") }
                    lastWasSpace = true
                } else {
                    collapsed.append(character)
                    lastWasSpace = false
                }
            }
            current += collapsed
        }

        /// Ends the line being built. `force` writes an empty line too, as a line break does.
        mutating func flush(force: Bool = false) {
            if inCell {
                if !current.isEmpty, current.last != " " { current += " " }
                return
            }
            var line = current
            while line.last == " " { line.removeLast() }
            if line.isEmpty && !force {
                linePrefix = ""
                current = ""
                return
            }
            let quote = inQuote > 0 ? "> " : ""
            lines.append(line.isEmpty ? (inQuote > 0 ? ">" : "") : quote + linePrefix + line)
            current = ""
            linePrefix = ""
        }

        mutating func tag(_ raw: String) {
            let isClosing = raw.hasPrefix("/")
            let body = isClosing ? String(raw.dropFirst()) : raw
            let name = body.prefix(while: { !$0.isWhitespace && $0 != "/" }).lowercased()
            let attributes = String(body.dropFirst(name.count))

            if skipDepth > 0 {
                if name == "script" || name == "style" {
                    if isClosing { skipDepth -= 1 } else { skipDepth += 1 }
                }
                return
            }

            switch name {
            case "script", "style", "head":
                if !isClosing { skipDepth += 1 }
            case "br":
                if inCell { current += " " } else { flush(force: true) }
            case "div", "p":
                flush()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !isClosing { linePrefix = String(repeating: "#", count: Int(String(name.dropFirst())) ?? 1) + " " }
            case "blockquote":
                flush()
                inQuote = max(0, inQuote + (isClosing ? -1 : 1))
            case "ul", "ol":
                flush()
                if isClosing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    lists.append((name == "ol", 0))
                }
            case "li":
                flush()
                if !isClosing, !lists.isEmpty {
                    lists[lists.count - 1].counter += 1
                    let list = lists[lists.count - 1]
                    let indent = String(repeating: "  ", count: lists.count - 1)
                    linePrefix = indent + (list.ordered ? "\(list.counter). " : "- ")
                }
            case "b", "strong":
                current += "**"
            case "i", "em":
                current += "*"
            case "s", "strike", "del":
                current += "~~"
            case "tt", "code":
                current += "`"
            case "a":
                if isClosing {
                    closeAnchor()
                } else {
                    anchors.append((nil, Self.attribute("href", in: attributes) ?? "", current.count))
                }
            case "img":
                let alt = Self.attribute("alt", in: attributes) ?? ""
                current += alt.isEmpty ? "[image]" : "[image: \(alt)]"
            case "table":
                flush()
                if isClosing { emitTable() } else { table = [] }
            case "tr":
                if isClosing {
                    if let finished = row { table.append(finished) }
                    row = nil
                } else {
                    row = []
                }
            case "td", "th":
                if isClosing {
                    row?.append(current.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|"))
                    current = ""
                    inCell = false
                } else {
                    flush()
                    inCell = true
                    current = ""
                }
            default:
                break
            }
        }

        mutating func closeAnchor() {
            guard let anchor = anchors.popLast() else { return }
            let label = String(current.dropFirst(anchor.outputLength))
            guard !anchor.href.isEmpty else { return }
            let visible = label.trimmingCharacters(in: .whitespaces)
            current =
                String(current.prefix(anchor.outputLength))
                + (visible.isEmpty ? anchor.href : "[\(visible)](\(anchor.href))")
        }

        mutating func emitTable() {
            guard let width = table.map(\.count).max(), width > 0 else { return }
            let rows = table.map { cells in cells + Array(repeating: "", count: width - cells.count) }
            for (offset, cells) in rows.enumerated() {
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if offset == 0 {
                    lines.append("|" + String(repeating: " --- |", count: width))
                }
            }
            table = []
        }

        func result() -> String {
            var output: [String] = []
            for line in lines {
                // One blank line at most in a row.
                if line.isEmpty, output.last?.isEmpty ?? true { continue }
                output.append(line)
            }
            while output.last?.isEmpty == true { output.removeLast() }
            return output.joined(separator: "\n")
        }

        static func attribute(_ name: String, in attributes: String) -> String? {
            let lowered = attributes.lowercased()
            guard let range = lowered.range(of: name + "=") else { return nil }
            let start = attributes.index(
                attributes.startIndex,
                offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound)
            )
            guard start < attributes.endIndex else { return nil }
            let first = attributes[start]
            if first == "\"" || first == "'" {
                let rest = attributes[attributes.index(after: start)...]
                guard let end = rest.firstIndex(of: first) else { return nil }
                return decode(String(rest[..<end]))
            }
            return decode(String(attributes[start...].prefix(while: { !$0.isWhitespace })))
        }

        static func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            var output = ""
            var index = text.startIndex
            while index < text.endIndex {
                if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                    let name = String(text[text.index(after: index) ..< semicolon])
                    if let decoded = entity(name) {
                        output += decoded
                        index = text.index(after: semicolon)
                        continue
                    }
                }
                output.append(text[index])
                index = text.index(after: index)
            }
            return output
        }

        static func entity(_ name: String) -> String? {
            switch name {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return " "
            default:
                var digits = Substring(name)
                guard digits.first == "#" else { return nil }
                digits = digits.dropFirst()
                let value: UInt32?
                if digits.first == "x" || digits.first == "X" {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
        }
    }
}

/// A note, ready to be written out in one of the export formats.
struct NotesExportItem: Equatable, Sendable {
    let id: String
    let title: String
    let folder: String
    let account: String
    let created: Date?
    let modified: Date?
    let plainText: String
    let bodyHTML: String
    let isPasswordProtected: Bool

    init(_ note: NotesScriptNote) {
        id = note.id
        title = note.title
        folder = note.folder
        account = note.account
        created = note.created
        modified = note.modified
        plainText = note.plainText
        bodyHTML = note.bodyHTML
        isPasswordProtected = note.isPasswordProtected
    }
}

enum NotesExportFormat: String, CaseIterable, Sendable {
    case json
    case markdown
    case html
}

enum NotesExporter {
    static func export(_ items: [NotesExportItem], as format: NotesExportFormat) throws -> String {
        switch format {
        case .json: return try json(items)
        case .markdown: return markdown(items)
        case .html: return html(items)
        }
    }

    /// A note as Markdown. A note locked with a password has no text to convert.
    static func markdown(_ item: NotesExportItem) -> String {
        item.isPasswordProtected ? "" : NotesHTMLToMarkdown.markdown(fromHTML: item.bodyHTML)
    }

    static func json(_ items: [NotesExportItem]) throws -> String {
        struct Entry: Encodable {
            let id: String
            let title: String
            let folder: String
            let account: String
            let created: String?
            let modified: String?
            let plainText: String
            let html: String
            let locked: Bool
        }
        let entries = items.map {
            Entry(
                id: $0.id,
                title: $0.title,
                folder: $0.folder,
                account: $0.account,
                created: NotesDates.iso($0.created),
                modified: NotesDates.iso($0.modified),
                plainText: $0.plainText,
                html: $0.bodyHTML,
                locked: $0.isPasswordProtected
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }

    /// Each note as Markdown after a block of front matter, with a line between notes.
    static func markdown(_ items: [NotesExportItem]) -> String {
        items.map { item in
            var front = ["---", "title: \(quoted(item.title))", "id: \(quoted(item.id))"]
            front.append("folder: \(quoted(item.folder))")
            front.append("account: \(quoted(item.account))")
            if let created = NotesDates.iso(item.created) { front.append("created: \(created)") }
            if let modified = NotesDates.iso(item.modified) { front.append("modified: \(modified)") }
            front.append("---")
            return front.joined(separator: "\n") + "\n\n" + markdown(item) + "\n"
        }.joined(separator: "\n")
    }

    /// One page with a section for each note.
    static func html(_ items: [NotesExportItem]) -> String {
        let sections = items.map { item -> String in
            let meta = [item.account, item.folder, NotesDates.iso(item.modified)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
            let body = item.isPasswordProtected ? "<p>This note is locked with a password.</p>" : item.bodyHTML
            return """
                <article data-note-id="\(NotesHTML.escape(item.id).replacingOccurrences(of: "\"", with: "&quot;"))">
                <p><small>\(NotesHTML.escape(meta))</small></p>
                \(body)
                </article>
                """
        }
        return """
            <!DOCTYPE html>
            <html>
            <head><meta charset="utf-8"><title>Notes</title></head>
            <body>
            \(sections.joined(separator: "\n<hr>\n"))
            </body>
            </html>
            """
    }

    /// A string in double quotes, which is valid YAML and JSON.
    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string.replacingOccurrences(of: "\\/", with: "/")
    }
}
