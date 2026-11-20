import Foundation

// Creating notes and folders through the Notes app's scripting interface.
//
// This file holds the logic that needs no Notes app, so that tests can cover it:
// validating a request, turning Markdown into the HTML that Notes accepts,
// and the fixed script that does the work.
// `NotesWriteTools.swift` connects it to the Notes service.

/// How the `body` of a new note is written.
enum NotesContentFormat: String, CaseIterable, Sendable {
    /// Text, shown as written.
    case plaintext
    /// Markdown, converted to the HTML subset that Notes keeps.
    case markdown
}

/// A request that the Notes service refuses, and the reason.
enum NotesWriteError: LocalizedError, CustomStringConvertible, Equatable {
    case invalid(String)
    case automationDenied
    case scriptFailed(String)

    var description: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid argument: \(message)"
        case .automationDenied:
            return
                "Not authorized to send Apple events to Notes. Enable iMCP in System Settings > Privacy & Security > Automation."
        case .scriptFailed(let message):
            return "Notes could not complete the request: \(message)"
        }
    }
}

/// A folder in the Notes app, named by the folders that contain it.
struct NotesFolderPath: Equatable, Sendable {
    /// The most folders that a path may name.
    static let maximumDepth = 10
    /// The longest name of one folder.
    static let maximumNameLength = 200

    /// The folders from the outermost to the one that the path names.
    let components: [String]

    /// Reads a path written as `Parent/Child`.
    ///
    /// A folder's name can't contain `/`, which separates the names in a path,
    /// so a path can't reach such a folder.
    /// Surrounding spaces in a name are dropped.
    static func parse(_ text: String) throws -> NotesFolderPath {
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count <= maximumDepth else {
            throw NotesWriteError.invalid("a folder path can have at most \(maximumDepth) folders")
        }
        for component in components {
            try NotesWriteInput.validateName(component, called: "a folder name", limit: maximumNameLength)
        }
        return NotesFolderPath(components: components)
    }
}

/// The arguments of a request to create a note or a folder, once checked.
enum NotesWriteInput {
    static let maximumTitleLength = 250
    static let maximumBodyLength = 200_000
    static let maximumAccountLength = 200

    /// Throws unless `name` is one line of text, not empty, and at most `limit` characters.
    ///
    /// Control characters, including line breaks, are refused:
    /// they have no place in a title or a name,
    /// and a line break in a title would end it early.
    static func validateName(_ name: String, called label: String, limit: Int) throws {
        guard !name.isEmpty else {
            throw NotesWriteError.invalid("\(label) can't be empty")
        }
        guard name.count <= limit else {
            throw NotesWriteError.invalid("\(label) can have at most \(limit) characters")
        }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw NotesWriteError.invalid("\(label) can't contain control characters or line breaks")
        }
    }

    static func validatedTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateName(title, called: "title", limit: maximumTitleLength)
        return title
    }

    static func validatedFolderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        try validateName(name, called: "name", limit: NotesFolderPath.maximumNameLength)
        guard !name.contains("/") else {
            throw NotesWriteError.invalid("name can't contain \"/\", which separates the folders in a path")
        }
        return name
    }

    static func validatedAccount(_ account: String) throws -> String {
        let account = account.trimmingCharacters(in: .whitespaces)
        try validateName(account, called: "account", limit: maximumAccountLength)
        return account
    }

    static func validatedBody(_ body: String) throws -> String {
        guard body.count <= maximumBodyLength else {
            throw NotesWriteError.invalid("body can have at most \(maximumBodyLength) characters")
        }
        return body
    }
}

/// The request to create a note, once checked.
struct NotesNoteRequest: Equatable, Sendable {
    let title: String
    let bodyHTML: String
    let folder: NotesFolderPath
    let account: String?
    let createMissingFolders: Bool

    /// Checks the arguments of `notes_create` and builds the HTML for the note.
    ///
    /// The note's first line is its title in Notes,
    /// so the HTML starts with the title and the body follows.
    init(
        title: String,
        body: String,
        format: NotesContentFormat,
        folder: String?,
        account: String?,
        createMissingFolders: Bool
    ) throws {
        let title = try NotesWriteInput.validatedTitle(title)
        let body = try NotesWriteInput.validatedBody(body)
        self.title = title
        self.folder = try folder.map(NotesFolderPath.parse) ?? NotesFolderPath(components: [])
        self.account = try account.map(NotesWriteInput.validatedAccount)
        self.createMissingFolders = createMissingFolders

        let content =
            switch format {
            case .plaintext: NotesHTML.html(fromPlainText: body)
            case .markdown: NotesMarkdown.html(from: body)
            }
        self.bodyHTML = "<div><h1>\(NotesHTML.escape(title))</h1></div>" + content
    }
}

/// The request to create a folder, once checked.
struct NotesFolderRequest: Equatable, Sendable {
    let name: String
    let parent: NotesFolderPath
    let account: String?

    init(name: String, parent: String?, account: String?) throws {
        self.name = try NotesWriteInput.validatedFolderName(name)
        self.parent = try parent.map(NotesFolderPath.parse) ?? NotesFolderPath(components: [])
        self.account = try account.map(NotesWriteInput.validatedAccount)
    }
}

/// HTML text.
enum NotesHTML {
    /// Escapes the characters that HTML reads as markup.
    static func escape(_ text: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Text as paragraphs, one for each line, with an empty paragraph for a blank line.
    static func html(fromPlainText text: String) -> String {
        lines(of: text).map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }.joined()
    }

    /// The lines of `text`, whichever line endings it uses, without a trailing empty line.
    static func lines(of text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// Markdown, converted to the HTML that Notes keeps when it reads a note's body.
///
/// Notes' scripting interface keeps less than Markdown can say:
/// - Links lose their addresses, so a link becomes its text followed by its address.
/// - Checklists become bullets, so a task keeps its state as ☐ or ☑ in front of the text.
/// - Numbered lists would merge into a bullet list before them,
///   so a numbered item is a paragraph that starts with its number.
/// - Block quotes become plain text, so a quote keeps its `>`.
/// - Headings are bold text in a larger size, not the Heading styles.
///
/// This reads the Markdown that people and assistants write,
/// not all of CommonMark: it leaves out HTML blocks, reference links, and setext headings.
/// Text that it doesn't understand stays as text.
enum NotesMarkdown {
    static func html(from markdown: String) -> String {
        var converter = Converter(lines: NotesHTML.lines(of: markdown))
        return converter.convert()
    }

    // MARK: - Blocks

    private struct Converter {
        let lines: [String]
        var index = 0
        var output = ""
        /// Whether a block follows a blank line or a list, and so needs space before it.
        var needsSpace = false

        init(lines: [String]) {
            self.lines = lines
        }

        mutating func convert() -> String {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    needsSpace = true
                    index += 1
                } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    codeBlock(fence: String(trimmed.prefix(3)))
                } else if let heading = Self.heading(in: trimmed) {
                    emit(heading)
                    index += 1
                } else if Self.isRule(trimmed) {
                    emit("<div>———</div>")
                    index += 1
                } else if isTableStart() {
                    table()
                } else if trimmed.hasPrefix(">") {
                    quote()
                } else if Self.listItem(in: line) != nil {
                    list()
                } else {
                    paragraph()
                }
            }
            return output
        }

        /// Adds a block, after the space that it needs.
        private mutating func emit(_ block: String) {
            if needsSpace && !output.isEmpty {
                output += "<div><br></div>"
            }
            needsSpace = false
            output += block
        }

        private mutating func codeBlock(fence: String) {
            index += 1
            var rows: [String] = []
            while index < lines.count {
                let line = lines[index]
                index += 1
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                rows.append(line.isEmpty ? "<div><br></div>" : "<div><tt>\(NotesHTML.escape(line))</tt></div>")
            }
            emit(rows.joined())
        }

        private static func heading(in line: String) -> String? {
            let hashes = line.prefix(while: { $0 == "#" })
            guard (1 ... 6).contains(hashes.count) else { return nil }
            let rest = line.dropFirst(hashes.count)
            guard rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // A closing run of # is part of the Markdown syntax.
            while text.hasSuffix("#") { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces)
            // The note's title is the heading at the top, so the body's headings start below it.
            let tag = hashes.count <= 2 ? "h2" : "h3"
            return "<\(tag)>\(inline(text))</\(tag)>"
        }

        private static func isRule(_ line: String) -> Bool {
            let characters = line.filter { $0 != " " }
            guard characters.count >= 3, let first = characters.first, "-*_".contains(first) else { return false }
            return characters.allSatisfy { $0 == first }
        }

        private mutating func quote() {
            var rows: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                var text = trimmed.dropFirst()
                if text.first == " " { text = text.dropFirst() }
                rows.append("<div>&gt; \(Self.inline(String(text)))</div>")
                index += 1
            }
            emit(rows.joined())
        }

        private mutating func paragraph() {
            var rows: [String] = []
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty
                    || (!rows.isEmpty
                        && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix(">")
                            || Self.heading(in: trimmed) != nil || Self.listItem(in: line) != nil))
                {
                    break
                }
                rows.append(Self.inline(trimmed))
                index += 1
            }
            emit("<div>\(rows.joined(separator: "<br>"))</div>")
        }

        // MARK: Lists

        private struct ListItem {
            /// The nesting of the item, starting at 0.
            var depth: Int
            var isNumbered: Bool
            /// The number as written, for a numbered item.
            var marker: String
            var text: String
        }

        private static func listItem(in line: String) -> ListItem? {
            var columns = 0
            var rest = Substring(line)
            while let first = rest.first, first == " " || first == "\t" {
                columns += first == "\t" ? 4 : 1
                rest = rest.dropFirst()
            }
            let depth = columns / 2

            if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
                var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
                // A task keeps its state, since a checklist can't be made.
                for (box, mark) in [("[ ] ", "☐ "), ("[x] ", "☑ "), ("[X] ", "☑ ")] where text.hasPrefix(box) {
                    text = mark + text.dropFirst(box.count)
                }
                if text == "[ ]" { text = "☐" }
                guard !text.isEmpty else { return nil }
                return ListItem(depth: depth, isNumbered: false, marker: "", text: text)
            }

            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let afterDigits = rest.dropFirst(digits.count)
            guard let separator = afterDigits.first, ".)".contains(separator),
                afterDigits.dropFirst().first == " "
            else { return nil }
            let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return ListItem(depth: depth, isNumbered: true, marker: "\(digits)\(separator)", text: text)
        }

        private mutating func list() {
            var items: [ListItem] = []
            while index < lines.count, let item = Self.listItem(in: lines[index]) {
                items.append(item)
                index += 1
            }

            var html = ""
            var bullets: [ListItem] = []
            func flushBullets() {
                guard !bullets.isEmpty else { return }
                html += Self.bulletList(bullets)
                bullets = []
            }
            for item in items {
                if item.isNumbered {
                    flushBullets()
                    let indent = String(repeating: "&nbsp;&nbsp;&nbsp;&nbsp;", count: item.depth)
                    html += "<div>\(indent)\(item.marker) \(Self.inline(item.text))</div>"
                } else {
                    bullets.append(item)
                }
            }
            flushBullets()
            emit(html)
            // Notes wants an empty line after a list.
            needsSpace = true
        }

        /// A bullet list, with a nested list directly inside the list that holds it,
        /// which is how Notes writes nested lists.
        private static func bulletList(_ items: [ListItem]) -> String {
            var html = ""
            var open = 0
            for item in items {
                // A list can go only one level deeper than the item before it.
                let level = min(item.depth + 1, open + 1)
                while open < level {
                    html += "<ul>"
                    open += 1
                }
                while open > level {
                    html += "</ul>"
                    open -= 1
                }
                html += "<li>\(inline(item.text))</li>"
            }
            html += String(repeating: "</ul>", count: open)
            return html
        }

        // MARK: Tables

        private func isTableStart() -> Bool {
            guard index + 1 < lines.count, lines[index].contains("|") else { return false }
            let divider = Self.cells(of: lines[index + 1])
            // The divider row has a cell of dashes, and colons for alignment, for each column.
            return !divider.isEmpty
                && divider.allSatisfy { $0.contains("-") && $0.allSatisfy { "-: ".contains($0) } }
        }

        private mutating func table() {
            let header = Self.cells(of: lines[index])
            index += 2
            var rows = [header.map { "<td><b>\(Self.inline($0))</b></td>" }]
            while index < lines.count, lines[index].contains("|"),
                !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
            {
                var cells = Self.cells(of: lines[index])
                // Every row has as many cells as the header.
                while cells.count < header.count { cells.append("") }
                rows.append(cells.prefix(header.count).map { "<td>\(Self.inline($0))</td>" })
                index += 1
            }
            let body = rows.map { "<tr>\($0.joined())</tr>" }.joined()
            emit("<table><tbody>\(body)</tbody></table>")
            needsSpace = true
        }

        /// The cells of a table row, without the pipes at its ends.
        private static func cells(of row: String) -> [String] {
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in row.trimmingCharacters(in: .whitespaces) {
                if escaped {
                    current.append(character == "|" ? "|" : "\\\(character)")
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "|" {
                    cells.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if escaped { current.append("\\") }
            cells.append(current)

            // A leading or trailing pipe adds an empty cell that isn't one.
            if row.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
            if row.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // MARK: Inline

        /// Text with Markdown's emphasis, code, and links, as HTML.
        static func inline(_ text: String) -> String {
            inline(Array(text))
        }

        private static func inline(_ characters: [Character]) -> String {
            var html = ""
            var i = 0
            while i < characters.count {
                let character = characters[i]

                // A backslash makes the next punctuation mark plain text.
                if character == "\\", i + 1 < characters.count, characters[i + 1].isASCII,
                    characters[i + 1].isPunctuation || characters[i + 1].isSymbol
                {
                    html += NotesHTML.escape(String(characters[i + 1]))
                    i += 2
                    continue
                }

                if character == "`" {
                    let run = characters[i...].prefix(while: { $0 == "`" }).count
                    if let end = closingRun(of: "`", length: run, in: characters, from: i + run) {
                        let code = String(characters[(i + run) ..< end]).trimmingCharacters(in: .whitespaces)
                        html += "<tt>\(NotesHTML.escape(code))</tt>"
                        i = end + run
                        continue
                    }
                    html += String(repeating: "`", count: run)
                    i += run
                    continue
                }

                if character == "[" || (character == "!" && i + 1 < characters.count && characters[i + 1] == "["),
                    let link = link(in: characters, at: i)
                {
                    html += link.html
                    i = link.end
                    continue
                }

                if let delimiter = emphasisDelimiter(in: characters, at: i),
                    let end = closingRun(
                        of: delimiter.character,
                        length: delimiter.length,
                        in: characters,
                        from: i + delimiter.length
                    ),
                    isClosing(characters, at: end, delimiter: delimiter),
                    end > i + delimiter.length
                {
                    let inner = Array(characters[(i + delimiter.length) ..< end])
                    html += "<\(delimiter.tag)>\(inline(inner))</\(delimiter.tag)>"
                    i = end + delimiter.length
                    continue
                }

                html += NotesHTML.escape(String(character))
                i += 1
            }
            return html
        }

        private struct Delimiter {
            let character: Character
            let length: Int
            let tag: String
        }

        /// The emphasis that opens at `i`, if one does.
        private static func emphasisDelimiter(in characters: [Character], at i: Int) -> Delimiter? {
            let character = characters[i]
            guard "*_~".contains(character) else { return nil }
            let next = i + 1 < characters.count ? characters[i + 1] : nil
            let previous = i > 0 ? characters[i - 1] : nil

            // An underscore inside a word, as in snake_case, is not emphasis.
            if character == "_", let previous, previous.isLetter || previous.isNumber { return nil }

            if character == "~" {
                guard next == "~" else { return nil }
                guard let after = i + 2 < characters.count ? characters[i + 2] : nil, !after.isWhitespace
                else { return nil }
                return Delimiter(character: "~", length: 2, tag: "s")
            }
            if next == character {
                guard let after = i + 2 < characters.count ? characters[i + 2] : nil, !after.isWhitespace
                else { return nil }
                return Delimiter(character: character, length: 2, tag: "b")
            }
            guard let next, !next.isWhitespace else { return nil }
            return Delimiter(character: character, length: 1, tag: "i")
        }

        /// Whether the run at `end` can close the emphasis that `delimiter` opens.
        private static func isClosing(_ characters: [Character], at end: Int, delimiter: Delimiter) -> Bool {
            guard end > 0, !characters[end - 1].isWhitespace else { return false }
            if delimiter.character == "_" {
                let after = end + delimiter.length
                if after < characters.count, characters[after].isLetter || characters[after].isNumber {
                    return false
                }
            }
            return true
        }

        /// The index of the next run of exactly `length` of `character` at or after `start`.
        private static func closingRun(
            of character: Character,
            length: Int,
            in characters: [Character],
            from start: Int
        ) -> Int? {
            var i = start
            while i < characters.count {
                if characters[i] == "\\" {
                    i += 2
                    continue
                }
                if characters[i] == character {
                    let run = characters[i...].prefix(while: { $0 == character }).count
                    if run == length { return i }
                    i += run
                    continue
                }
                i += 1
            }
            return nil
        }

        /// A link or an image at `start`, as its text followed by its address.
        private static func link(in characters: [Character], at start: Int) -> (html: String, end: Int)? {
            var i = start
            if characters[i] == "!" { i += 1 }
            guard i < characters.count, characters[i] == "[" else { return nil }

            var depth = 0
            var closing: Int?
            var j = i
            while j < characters.count {
                if characters[j] == "\\" {
                    j += 2
                    continue
                }
                if characters[j] == "[" { depth += 1 }
                if characters[j] == "]" {
                    depth -= 1
                    if depth == 0 {
                        closing = j
                        break
                    }
                }
                j += 1
            }
            guard let closing, closing + 1 < characters.count, characters[closing + 1] == "(" else { return nil }
            guard let end = characters[(closing + 2)...].firstIndex(of: ")") else { return nil }

            let label = Array(characters[(i + 1) ..< closing])
            // An address may be followed by a title, which Notes has no place for.
            let target =
                String(characters[(closing + 2) ..< end]).trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let text = inline(label)
            guard !target.isEmpty else { return (text, end + 1) }
            if String(label) == target { return (NotesHTML.escape(target), end + 1) }
            return ("\(text) (\(NotesHTML.escape(target)))", end + 1)
        }
    }
}

/// The script that creates notes and folders in the Notes app, and how to call it.
///
/// The script is fixed text.
/// A request's values never become part of its source:
/// each is passed to a handler as a parameter (see ``NSAppleScript/Subroutine``),
/// so a title, a folder name, or a note's body
/// can't change what the script does, however it is written.
enum NotesScripts {
    /// The script raises errors numbered 4001 and up, with messages that say what was not found.
    static let source = """
        -- Finds an account by name, or the default account when the name is empty.
        on resolveAccount(accountName)
        	tell application "Notes"
        		if accountName is "" then return default account
        		considering case
        			repeat with candidate in accounts
        				if (name of candidate) is accountName then return contents of candidate
        			end repeat
        		end considering
        	end tell
        	error "There is no Notes account named: " & accountName number 4001
        end resolveAccount

        -- Finds the folder named childName directly inside parentRef, an account or a folder.
        -- Folders are listed with their nested folders in some versions of Notes,
        -- so the folder's container must be parentRef.
        on findChild(parentRef, childName)
        	tell application "Notes"
        		set parentID to id of parentRef
        		considering case
        			repeat with candidate in (folders of parentRef)
        				if (name of candidate) is childName then
        					if (id of (container of candidate)) is parentID then return contents of candidate
        				end if
        			end repeat
        		end considering
        	end tell
        	return missing value
        end findChild

        -- Finds the folder at folderPath, a list of folder names, inside an account.
        -- An empty path names the account's default folder.
        on resolveFolder(accountName, folderPath, createMissing)
        	set theAccount to my resolveAccount(accountName)
        	if (count of folderPath) is 0 then
        		tell application "Notes" to return default folder of theAccount
        	end if
        	set walker to theAccount
        	repeat with part in folderPath
        		set partName to contents of part
        		set found to my findChild(walker, partName)
        		if found is missing value then
        			if not createMissing then error "There is no folder named: " & partName number 4002
        			tell application "Notes" to set found to make new folder at walker with properties {name:partName}
        		end if
        		set walker to found
        	end repeat
        	return walker
        end resolveFolder

        -- Creates a note whose body is HTML, and returns {id, name, folder name, account name}.
        on createNote(accountName, folderPath, noteBody, createMissing)
        	set theAccount to my resolveAccount(accountName)
        	set targetFolder to my resolveFolder(accountName, folderPath, createMissing)
        	tell application "Notes"
        		set newNote to make new note at targetFolder with properties {body:noteBody}
        		return {id of newNote, name of newNote, name of targetFolder, name of theAccount}
        	end tell
        end createNote

        -- Creates a folder, and returns {id, name, account name}.
        -- It refuses a name that the parent already has.
        on createFolder(accountName, parentPath, folderName)
        	set theAccount to my resolveAccount(accountName)
        	set parentRef to theAccount
        	if (count of parentPath) > 0 then set parentRef to my resolveFolder(accountName, parentPath, false)
        	set existing to my findChild(parentRef, folderName)
        	if existing is not missing value then error "There is already a folder named: " & folderName number 4003
        	tell application "Notes"
        		set newFolder to make new folder at parentRef with properties {name:folderName}
        		return {id of newFolder, name of newFolder, name of theAccount}
        	end tell
        end createFolder
        """

    static func createNote(_ request: NotesNoteRequest) -> NSAppleScript.Subroutine {
        NSAppleScript.Subroutine(
            "createNote",
            [
                .string(request.account ?? ""),
                .strings(request.folder.components),
                .string(request.bodyHTML),
                .boolean(request.createMissingFolders),
            ]
        )
    }

    static func createFolder(_ request: NotesFolderRequest) -> NSAppleScript.Subroutine {
        NSAppleScript.Subroutine(
            "createFolder",
            [
                .string(request.account ?? ""),
                .strings(request.parent.components),
                .string(request.name),
            ]
        )
    }
}
