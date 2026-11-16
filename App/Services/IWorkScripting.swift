import Foundation
import MCP

// Pages, Numbers, and Keynote through their scripting interfaces.
//
// This file holds the logic that needs none of the three apps, so that tests can cover it:
// checking a request, the fixed scripts, and turning what a script returns into values.
// `IWork.swift` connects it to the iWork service.

/// One of the three apps.
enum IWorkApp: String, CaseIterable, Sendable {
    case pages
    case numbers
    case keynote

    /// The bundle identifier that the scripts address, so that a renamed app still answers.
    var bundleID: String {
        switch self {
        case .pages: return "com.apple.Pages"
        case .numbers: return "com.apple.Numbers"
        case .keynote: return "com.apple.Keynote"
        }
    }

    var displayName: String {
        switch self {
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .keynote: return "Keynote"
        }
    }
}

/// A request that the iWork service refuses, and the reason.
enum IWorkError: LocalizedError, CustomStringConvertible, Equatable {
    case invalid(String)
    case notRunning(IWorkApp)
    case automationDenied(IWorkApp)
    case scriptFailed(IWorkApp, String)

    var description: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid argument: \(message)"
        case .notRunning(let app):
            return
                "\(app.displayName) isn't open. iMCP doesn't start it. Open the document in \(app.displayName) first."
        case .automationDenied(let app):
            return
                "Not authorized to send Apple events to \(app.displayName). Enable iMCP in System Settings > Privacy & Security > Automation."
        case .scriptFailed(let app, let message):
            return "\(app.displayName) could not complete the request: \(message)"
        }
    }
}

/// The AppleScript error number that the scripts use for a document that isn't open.
let iWorkNoSuchDocumentNumber = 1001

/// The cells of a table that a request names.
struct IWorkCellRange: Equatable, Sendable {
    /// The most cells that one read returns.
    static let maximumCells = 1_000
    /// The widest column that Numbers has is XFD, so three letters are enough.
    static let maximumColumnLetters = 3
    static let maximumRowDigits = 7

    let firstRow: Int
    let firstColumn: Int
    let lastRow: Int
    let lastColumn: Int

    var rowCount: Int { lastRow - firstRow + 1 }
    var columnCount: Int { lastColumn - firstColumn + 1 }
    var cellCount: Int { rowCount * columnCount }

    /// The range in the form that Numbers reads, such as `A1:C3`.
    var text: String {
        "\(IWorkCellAddress.name(row: firstRow, column: firstColumn)):\(IWorkCellAddress.name(row: lastRow, column: lastColumn))"
    }

    /// Reads `A1` or `A1:C3`, and refuses a range of more than ``maximumCells`` cells.
    static func parse(_ text: String) throws -> IWorkCellRange {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            throw IWorkError.invalid("range must look like A1 or A1:C3")
        }
        let first = try IWorkCellAddress.parse(String(parts[0]), called: "range")
        let last = parts.count == 2 ? try IWorkCellAddress.parse(String(parts[1]), called: "range") : first
        guard first.row <= last.row, first.column <= last.column else {
            throw IWorkError.invalid("range must run from its top left cell to its bottom right cell, as in A1:C3")
        }
        let range = IWorkCellRange(
            firstRow: first.row,
            firstColumn: first.column,
            lastRow: last.row,
            lastColumn: last.column
        )
        guard range.cellCount <= maximumCells else {
            throw IWorkError.invalid(
                "range holds \(range.cellCount) cells, and one read returns at most \(maximumCells). Ask for a smaller range"
            )
        }
        return range
    }

    /// The range that reads the top left of a table, up to ``maximumCells`` cells.
    static func leading(rows: Int, columns: Int) -> IWorkCellRange? {
        guard rows > 0, columns > 0 else { return nil }
        let width = min(columns, 26)
        let height = min(rows, max(1, maximumCells / width))
        return IWorkCellRange(firstRow: 1, firstColumn: 1, lastRow: height, lastColumn: width)
    }

    /// Whether the range lies inside a table of this size.
    func fits(rows: Int, columns: Int) -> Bool {
        lastRow <= rows && lastColumn <= columns
    }
}

/// One cell of a table, such as `B2`.
struct IWorkCellAddress: Equatable, Sendable {
    /// Both start at 1.
    let row: Int
    let column: Int

    var text: String { Self.name(row: row, column: column) }

    static func parse(_ text: String, called label: String = "cell") throws -> IWorkCellAddress {
        let text = text.trimmingCharacters(in: .whitespaces).uppercased()
        let letters = text.prefix(while: { $0.isASCII && $0.isLetter })
        let digits = text.dropFirst(letters.count)
        guard !letters.isEmpty, letters.count <= IWorkCellRange.maximumColumnLetters,
            !digits.isEmpty, digits.count <= IWorkCellRange.maximumRowDigits,
            digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            let row = Int(digits), row >= 1
        else {
            throw IWorkError.invalid("\(label) must name a cell, such as B2")
        }
        var column = 0
        for letter in letters.unicodeScalars {
            column = column * 26 + Int(letter.value) - 64
        }
        return IWorkCellAddress(row: row, column: column)
    }

    /// The name of a cell: column 1, row 1 is `A1`, and column 27, row 3 is `AA3`.
    static func name(row: Int, column: Int) -> String {
        var letters = ""
        var remaining = column
        while remaining > 0 {
            let index = (remaining - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + index))) + letters
            remaining = (remaining - 1) / 26
        }
        return "\(letters)\(row)"
    }
}

/// The arguments of the iWork tools, once checked.
enum IWorkInput {
    static let maximumNameLength = 500
    static let maximumTextLength = 200_000
    static let maximumSlideTextLength = 20_000
    static let maximumCellTextLength = 20_000

    static let defaultReadCharacters = 20_000
    static let maximumReadCharacters = 200_000
    static let defaultReadSlides = 50
    static let maximumReadSlides = 200

    /// A document, sheet, or table name: not empty, and short.
    ///
    /// A name is compared with the apps' names as it is written, so it isn't trimmed.
    static func validatedName(_ name: String, called label: String) throws -> String {
        guard !name.isEmpty else { throw IWorkError.invalid("\(label) can't be empty") }
        guard name.count <= maximumNameLength else {
            throw IWorkError.invalid("\(label) can have at most \(maximumNameLength) characters")
        }
        return name
    }

    static func validatedText(_ text: String, called label: String, limit: Int) throws -> String {
        guard !text.isEmpty else { throw IWorkError.invalid("\(label) can't be empty") }
        guard text.count <= limit else {
            throw IWorkError.invalid("\(label) can have at most \(limit) characters")
        }
        return text
    }

    /// The value for a cell, as the script receives it.
    static func cellValue(from value: Value) throws -> NSAppleScript.Subroutine.Parameter {
        switch value {
        case .string(let text):
            guard text.count <= maximumCellTextLength else {
                throw IWorkError.invalid("value can have at most \(maximumCellTextLength) characters")
            }
            return .string(text)
        case .bool(let flag):
            return .boolean(flag)
        case .int(let number):
            return .number(Double(number))
        case .double(let number):
            guard number.isFinite else { throw IWorkError.invalid("value must be a finite number") }
            return .number(number)
        default:
            throw IWorkError.invalid("value must be a string, a number, or true or false")
        }
    }
}

/// The scripts, and the calls to their handlers.
///
/// A script is fixed text that names the app by its bundle identifier.
/// Everything that a request carries reaches a handler as an argument,
/// never as part of the script's source.
enum IWorkScripts {
    static func source(for app: IWorkApp) -> String {
        switch app {
        case .pages: return pages
        case .numbers: return numbers
        case .keynote: return keynote
        }
    }

    // MARK: Calls

    static func listDocuments() -> NSAppleScript.Subroutine {
        .init("listdocuments", [])
    }

    static func readPages(document: String) -> NSAppleScript.Subroutine {
        .init("readpages", [.string(document)])
    }

    static func describeNumbers(document: String) -> NSAppleScript.Subroutine {
        .init("describenumbers", [.string(document)])
    }

    static func readNumbers(
        document: String,
        sheet: String,
        table: String,
        range: IWorkCellRange
    ) -> NSAppleScript.Subroutine {
        .init("readnumbers", [.string(document), .string(sheet), .string(table), .string(range.text)])
    }

    static func readKeynote(document: String, slides: Int) -> NSAppleScript.Subroutine {
        .init("readkeynote", [.string(document), .number(Double(slides))])
    }

    static func appendPages(document: String, text: String) -> NSAppleScript.Subroutine {
        .init("appendpages", [.string(document), .string(text)])
    }

    static func setNumbersCell(
        document: String,
        sheet: String,
        table: String,
        cell: IWorkCellAddress,
        value: NSAppleScript.Subroutine.Parameter
    ) -> NSAppleScript.Subroutine {
        .init("setnumberscell", [.string(document), .string(sheet), .string(table), .string(cell.text), value])
    }

    static func addKeynoteSlide(
        document: String,
        title: String,
        body: String,
        notes: String
    ) -> NSAppleScript.Subroutine {
        .init("addkeynoteslide", [.string(document), .string(title), .string(body), .string(notes)])
    }

    // MARK: Sources

    /// The handler that answers with the names of the open documents, shared by the three scripts.
    private static func listHandler(_ bundleID: String) -> String {
        """
        on listdocuments()
            tell application id "\(bundleID)"
                set out to {}
                repeat with d in documents
                    set end of out to {name of d, modified of d}
                end repeat
                return out
            end tell
        end listdocuments
        """
    }

    /// The lines that find a document by name, or fail with ``iWorkNoSuchDocumentNumber``.
    /// They run inside a `tell application` block.
    private static let findDocument = """
        set matches to (documents whose name is docName)
        if (count of matches) is 0 then error "No open document is named " & docName number \(iWorkNoSuchDocumentNumber)
        set d to item 1 of matches
        """

    private static var pages: String {
        """
        \(listHandler("com.apple.Pages"))

        on readpages(docName)
            tell application id "com.apple.Pages"
                \(findDocument)
                return body text of d as text
            end tell
        end readpages

        on appendpages(docName, newText)
            tell application id "com.apple.Pages"
                \(findDocument)
                tell body text of d
                    make new paragraph at end with data (return & newText)
                end tell
                return true
            end tell
        end appendpages
        """
    }

    private static var numbers: String {
        """
        \(listHandler("com.apple.Numbers"))

        on describenumbers(docName)
            tell application id "com.apple.Numbers"
                \(findDocument)
                set out to {}
                repeat with sh in sheets of d
                    set tableList to {}
                    repeat with tb in tables of sh
                        set end of tableList to {name of tb, row count of tb, column count of tb}
                    end repeat
                    set end of out to {name of sh, tableList}
                end repeat
                return out
            end tell
        end describenumbers

        on readnumbers(docName, sheetName, tableName, rangeText)
            tell application id "com.apple.Numbers"
                \(findDocument)
                set sh to item 1 of (sheets of d whose name is sheetName)
                set tb to item 1 of (tables of sh whose name is tableName)
                set r to range rangeText of tb
                set out to {}
                repeat with i from 1 to (count of rows of r)
                    set end of out to (value of every cell of row i of r)
                end repeat
                return out
            end tell
        end readnumbers

        on setnumberscell(docName, sheetName, tableName, cellName, newValue)
            tell application id "com.apple.Numbers"
                \(findDocument)
                set sh to item 1 of (sheets of d whose name is sheetName)
                set tb to item 1 of (tables of sh whose name is tableName)
                set value of cell cellName of tb to newValue
                return true
            end tell
        end setnumberscell
        """
    }

    private static var keynote: String {
        """
        \(listHandler("com.apple.Keynote"))

        on readkeynote(docName, maxSlides)
            tell application id "com.apple.Keynote"
                \(findDocument)
                set total to count of slides of d
                set shown to total
                if shown > maxSlides then set shown to maxSlides
                set out to {}
                repeat with i from 1 to shown
                    set s to slide i of d
                    set slideTitle to ""
                    set slideBody to ""
                    set slideNotes to ""
                    try
                        set slideTitle to (object text of default title item of s) as text
                    end try
                    try
                        set slideBody to (object text of default body item of s) as text
                    end try
                    try
                        set slideNotes to (presenter notes of s) as text
                    end try
                    set end of out to {slideTitle, slideBody, slideNotes}
                end repeat
                return {total, out}
            end tell
        end readkeynote

        on addkeynoteslide(docName, slideTitle, slideBody, slideNotes)
            tell application id "com.apple.Keynote"
                \(findDocument)
                tell d
                    set s to make new slide
                    if slideTitle is not "" then set object text of default title item of s to slideTitle
                    if slideBody is not "" then set object text of default body item of s to slideBody
                    if slideNotes is not "" then set presenter notes of s to slideNotes
                    return count of slides
                end tell
            end tell
        end addkeynoteslide
        """
    }
}

/// Turns what a script returns into values.
enum IWorkResult {
    /// Converts a descriptor: lists become arrays, and an empty cell becomes `null`.
    static func value(from descriptor: NSAppleEventDescriptor) -> Value {
        switch descriptor.descriptorType {
        case DescType(typeAEList):
            guard descriptor.numberOfItems > 0 else { return .array([]) }
            return .array((1 ... descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }.map(value(from:)))
        case DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse):
            return .bool(descriptor.booleanValue)
        case DescType(typeSInt16), DescType(typeSInt32), DescType(typeUInt32), DescType(typeSInt64):
            return .int(Int(descriptor.int32Value))
        case DescType(typeIEEE32BitFloatingPoint), DescType(typeIEEE64BitFloatingPoint):
            return .double(descriptor.doubleValue)
        case DescType(typeLongDateTime):
            return descriptor.dateValue.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        case DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar):
            return .string(descriptor.stringValue ?? "")
        default:
            // A missing value, or a type that a document can't hold in a cell.
            return .null
        }
    }

    /// The items of a list descriptor.
    static func items(of descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == DescType(typeAEList), descriptor.numberOfItems > 0 else { return [] }
        return (1 ... descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    /// Cuts `text` to `limit` characters, and says whether it did.
    static func truncated(_ text: String, to limit: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// The document names and modification flags that `listdocuments` returns.
    static func documents(from descriptor: NSAppleEventDescriptor) -> [(name: String, modified: Bool)] {
        items(of: descriptor).compactMap { entry in
            let fields = items(of: entry)
            guard fields.count >= 2, let name = fields[0].stringValue else { return nil }
            return (name, fields[1].booleanValue)
        }
    }

    /// A table in the answer of `describenumbers`.
    struct NumbersTable: Equatable {
        let name: String
        let rows: Int
        let columns: Int
    }

    struct NumbersSheet: Equatable {
        let name: String
        let tables: [NumbersTable]
    }

    static func numbersSheets(from descriptor: NSAppleEventDescriptor) -> [NumbersSheet] {
        items(of: descriptor).compactMap { sheet in
            let fields = items(of: sheet)
            guard fields.count >= 2, let name = fields[0].stringValue else { return nil }
            let tables: [NumbersTable] = items(of: fields[1]).compactMap { table in
                let parts = items(of: table)
                guard parts.count >= 3, let tableName = parts[0].stringValue else { return nil }
                return NumbersTable(
                    name: tableName,
                    rows: Int(parts[1].int32Value),
                    columns: Int(parts[2].int32Value)
                )
            }
            return NumbersSheet(name: name, tables: tables)
        }
    }
}
