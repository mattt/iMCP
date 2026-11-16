import AppKit
import Foundation
import MCP
import OSLog

private let log = Logger.service("iwork")

/// Runs the scripts of Pages, Numbers, and Keynote.
///
/// The iWork service uses the apps through `NSAppleScript`;
/// tests use a stand-in that sends nothing.
protocol IWorkScriptRunning: Sendable {
    /// Whether the app is open. A script would start it otherwise, which iMCP never does.
    func isRunning(_ app: IWorkApp) -> Bool

    /// Runs `subroutine` of the app's script and returns what it returns.
    func run(_ app: IWorkApp, calling subroutine: NSAppleScript.Subroutine) async throws -> NSAppleEventDescriptor
}

/// Runs the scripts in the apps, which ask the person to allow it the first time for each app.
struct AppleIWorkRunner: IWorkScriptRunning {
    func isRunning(_ app: IWorkApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func run(_ app: IWorkApp, calling subroutine: NSAppleScript.Subroutine) async throws -> NSAppleEventDescriptor {
        guard isRunning(app) else { throw IWorkError.notRunning(app) }
        do {
            return try await NSAppleScript.execute(IWorkScripts.source(for: app), calling: subroutine)
        } catch let error as NSAppleScript.ExecutionError {
            switch error.number {
            case Int(errAEEventNotPermitted):
                throw IWorkError.automationDenied(app)
            case iWorkNoSuchDocumentNumber:
                throw IWorkError.invalid(error.message)
            default:
                log.error("\(app.displayName) script failed: \(error.message)")
                throw IWorkError.scriptFailed(app, error.message)
            }
        }
    }
}

/// Reads and edits the documents that are open in Pages, Numbers, and Keynote.
///
/// The three apps are scripted, not read from disk,
/// so the tools see a document as the app shows it, including changes that aren't saved.
/// The tools that change a document are new, so they start off until the person turns on "Allow writes".
final class IWorkService: Service {
    static let shared = IWorkService()

    var tools: [Tool] {
        // An explicit return keeps the protocol's result builder from rewriting the array.
        return IWorkTools.tools(runner: AppleIWorkRunner())
    }

    var writesEnabledByDefault: Bool { false }
}

enum IWorkTools {
    static func tools(runner: any IWorkScriptRunning) -> [Tool] {
        [
            Tool(
                name: "iwork_documents",
                description:
                    "List the documents that are open in Pages, Numbers, and Keynote, with each one's name and whether it has unsaved changes. Apps that aren't open are listed as notRunning, and iMCP doesn't start them. The first time for each app, macOS asks whether iMCP may control it.",
                inputSchema: .object(
                    properties: [
                        "app": .string(
                            description: "Only list the documents of this app. Leave it out for all three",
                            enum: IWorkApp.allCases.map { .string($0.rawValue) }
                        )
                    ],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "List iWork Documents",
                    readOnlyHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                let apps = try app("app", in: arguments).map { [$0] } ?? IWorkApp.allCases
                var documents: [Value] = []
                var notRunning: [Value] = []
                for app in apps {
                    guard runner.isRunning(app) else {
                        notRunning.append(.string(app.rawValue))
                        continue
                    }
                    let result = try await runner.run(app, calling: IWorkScripts.listDocuments())
                    for document in IWorkResult.documents(from: result) {
                        documents.append([
                            "app": .string(app.rawValue),
                            "name": .string(document.name),
                            "hasUnsavedChanges": .bool(document.modified),
                        ])
                    }
                }
                return [
                    "documents": .array(documents),
                    "notRunning": .array(notRunning),
                ] as Value
            },

            Tool(
                name: "iwork_read_document",
                description:
                    "Read an open document. Pages gives the body text. Keynote gives each slide's title, body, and presenter notes. Numbers first gives the sheets and tables with their sizes; name a table to read its cells, up to \(IWorkCellRange.maximumCells) at a time. Documents with the same name are not told apart: the first one is read.",
                inputSchema: .object(
                    properties: [
                        "app": .string(
                            description: "The app that has the document open",
                            enum: IWorkApp.allCases.map { .string($0.rawValue) }
                        ),
                        "document": .string(description: "The document's name, as iwork_documents lists it"),
                        "sheet": .string(
                            description:
                                "Numbers only: the sheet to read. Leave it out for the first sheet that has a table"
                        ),
                        "table": .string(
                            description:
                                "Numbers only: the table to read. Leave it out to get the list of sheets and tables instead of cells"
                        ),
                        "range": .string(
                            description:
                                "Numbers only: the cells to read, such as A1:D20. Leave it out for the top left of the table"
                        ),
                        "maxCharacters": .integer(
                            description: "Pages only: the most characters of text to return",
                            default: .int(IWorkInput.defaultReadCharacters),
                            minimum: 1,
                            maximum: IWorkInput.maximumReadCharacters
                        ),
                        "maxSlides": .integer(
                            description: "Keynote only: the most slides to return, from the first",
                            default: .int(IWorkInput.defaultReadSlides),
                            minimum: 1,
                            maximum: IWorkInput.maximumReadSlides
                        ),
                    ],
                    required: ["app", "document"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Read iWork Document",
                    readOnlyHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                guard let app = try app("app", in: arguments) else {
                    throw IWorkError.invalid("app is required")
                }
                let document = try IWorkInput.validatedName(
                    try requiredString("document", in: arguments),
                    called: "document"
                )
                switch app {
                case .pages:
                    return try await readPages(document, arguments: arguments, runner: runner)
                case .numbers:
                    return try await readNumbers(document, arguments: arguments, runner: runner)
                case .keynote:
                    return try await readKeynote(document, arguments: arguments, runner: runner)
                }
            },

            Tool(
                name: "iwork_pages_append_text",
                description:
                    "Add text as a new paragraph at the end of the body of an open Pages document. It only adds: nothing that is there is changed or removed. The document isn't saved, so the change shows in Pages and can be undone there. Allowed only while \"Allow writes\" is on in iMCP's iWork settings.",
                inputSchema: .object(
                    properties: [
                        "document": .string(description: "The document's name, as iwork_documents lists it"),
                        "text": .string(
                            description:
                                "The text to add, up to \(IWorkInput.maximumTextLength) characters"
                        ),
                    ],
                    required: ["document", "text"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Append Text to Pages Document",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                let document = try IWorkInput.validatedName(
                    try requiredString("document", in: arguments),
                    called: "document"
                )
                let text = try IWorkInput.validatedText(
                    try requiredString("text", in: arguments),
                    called: "text",
                    limit: IWorkInput.maximumTextLength
                )
                _ = try await runner.run(.pages, calling: IWorkScripts.appendPages(document: document, text: text))
                return ["app": "pages", "document": .string(document), "appended": true] as Value
            },

            Tool(
                name: "iwork_numbers_set_cell",
                description:
                    "Set one cell of a table in an open Numbers document. A string is entered as text, a number as a number, and true or false as a boolean. Numbers reads a string that starts with = as a formula. This replaces what the cell held. The document isn't saved, so the change shows in Numbers and can be undone there. Allowed only while \"Allow writes\" is on in iMCP's iWork settings.",
                inputSchema: .object(
                    properties: [
                        "document": .string(description: "The document's name, as iwork_documents lists it"),
                        "sheet": .string(
                            description: "The sheet's name. Leave it out for the first sheet that has a table"
                        ),
                        "table": .string(
                            description: "The table's name. Leave it out for the first table of the sheet"
                        ),
                        "cell": .string(description: "The cell to set, such as B2"),
                        "value": .anyOf([.string(), .number(), .boolean()]),
                    ],
                    required: ["document", "cell", "value"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Set Numbers Cell",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                let document = try IWorkInput.validatedName(
                    try requiredString("document", in: arguments),
                    called: "document"
                )
                let cell = try IWorkCellAddress.parse(try requiredString("cell", in: arguments))
                guard let rawValue = arguments["value"], !rawValue.isNull else {
                    throw IWorkError.invalid("value is required")
                }
                let value = try IWorkInput.cellValue(from: rawValue)
                let (sheet, table, sizes) = try await resolveNumbersTable(
                    document: document,
                    sheet: try string("sheet", in: arguments),
                    table: try string("table", in: arguments),
                    runner: runner
                )
                guard
                    IWorkCellRange(
                        firstRow: cell.row,
                        firstColumn: cell.column,
                        lastRow: cell.row,
                        lastColumn: cell.column
                    )
                    .fits(rows: sizes.rows, columns: sizes.columns)
                else {
                    throw IWorkError.invalid(
                        "\(cell.text) is outside the table, which has \(sizes.rows) rows and \(sizes.columns) columns"
                    )
                }
                _ = try await runner.run(
                    .numbers,
                    calling: IWorkScripts.setNumbersCell(
                        document: document,
                        sheet: sheet,
                        table: table,
                        cell: cell,
                        value: value
                    )
                )
                return [
                    "app": "numbers", "document": .string(document), "sheet": .string(sheet),
                    "table": .string(table), "cell": .string(cell.text),
                ] as Value
            },

            Tool(
                name: "iwork_keynote_add_slide",
                description:
                    "Add a slide at the end of an open Keynote presentation, with the default layout. Title and body fill the layout's title and body, and notes become the presenter notes. If the layout has no title or body, that part is left empty. It only adds: no existing slide is changed. The presentation isn't saved, so the change shows in Keynote and can be undone there. Allowed only while \"Allow writes\" is on in iMCP's iWork settings.",
                inputSchema: .object(
                    properties: [
                        "document": .string(description: "The presentation's name, as iwork_documents lists it"),
                        "title": .string(description: "The slide's title"),
                        "body": .string(description: "The slide's body text"),
                        "notes": .string(description: "The slide's presenter notes"),
                    ],
                    required: ["document"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Add Keynote Slide",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                let document = try IWorkInput.validatedName(
                    try requiredString("document", in: arguments),
                    called: "document"
                )
                let limit = IWorkInput.maximumSlideTextLength
                func slideText(_ name: String) throws -> String {
                    let text = try string(name, in: arguments) ?? ""
                    guard text.count <= limit else {
                        throw IWorkError.invalid("\(name) can have at most \(limit) characters")
                    }
                    return text
                }
                let result = try await runner.run(
                    .keynote,
                    calling: IWorkScripts.addKeynoteSlide(
                        document: document,
                        title: try slideText("title"),
                        body: try slideText("body"),
                        notes: try slideText("notes")
                    )
                )
                return [
                    "app": "keynote", "document": .string(document),
                    "slideCount": .int(Int(result.int32Value)),
                ] as Value
            },
        ]
    }

    // MARK: - Reading

    private static func readPages(
        _ document: String,
        arguments: [String: Value],
        runner: any IWorkScriptRunning
    ) async throws -> Value {
        let limit = try integer("maxCharacters", in: arguments, default: IWorkInput.defaultReadCharacters)
        guard (1 ... IWorkInput.maximumReadCharacters).contains(limit) else {
            throw IWorkError.invalid("maxCharacters must be from 1 to \(IWorkInput.maximumReadCharacters)")
        }
        let result = try await runner.run(.pages, calling: IWorkScripts.readPages(document: document))
        let (text, wasTruncated) = IWorkResult.truncated(result.stringValue ?? "", to: limit)
        return [
            "app": "pages", "document": .string(document),
            "text": .string(text), "truncated": .bool(wasTruncated),
        ] as Value
    }

    private static func readKeynote(
        _ document: String,
        arguments: [String: Value],
        runner: any IWorkScriptRunning
    ) async throws -> Value {
        let limit = try integer("maxSlides", in: arguments, default: IWorkInput.defaultReadSlides)
        guard (1 ... IWorkInput.maximumReadSlides).contains(limit) else {
            throw IWorkError.invalid("maxSlides must be from 1 to \(IWorkInput.maximumReadSlides)")
        }
        let result = try await runner.run(
            .keynote,
            calling: IWorkScripts.readKeynote(document: document, slides: limit)
        )
        let parts = IWorkResult.items(of: result)
        guard parts.count >= 2 else { throw IWorkError.scriptFailed(.keynote, "Keynote returned an unexpected answer") }
        let slides: [Value] = IWorkResult.items(of: parts[1]).enumerated().map { index, slide in
            let fields = IWorkResult.items(of: slide).map { $0.stringValue ?? "" }
            return [
                "number": .int(index + 1),
                "title": .string(fields.count > 0 ? fields[0] : ""),
                "body": .string(fields.count > 1 ? fields[1] : ""),
                "presenterNotes": .string(fields.count > 2 ? fields[2] : ""),
            ]
        }
        return [
            "app": "keynote", "document": .string(document),
            "slideCount": .int(Int(parts[0].int32Value)),
            "slides": .array(slides),
        ] as Value
    }

    private static func readNumbers(
        _ document: String,
        arguments: [String: Value],
        runner: any IWorkScriptRunning
    ) async throws -> Value {
        let sheetArgument = try string("sheet", in: arguments)
        let tableArgument = try string("table", in: arguments)
        let rangeArgument = try string("range", in: arguments)

        let described = try await runner.run(.numbers, calling: IWorkScripts.describeNumbers(document: document))
        let sheets = IWorkResult.numbersSheets(from: described)

        // Without a table, answer with the structure, so the caller sees what there is to read.
        guard tableArgument != nil || rangeArgument != nil else {
            return [
                "app": "numbers", "document": .string(document),
                "sheets": .array(
                    sheets.map { sheet in
                        [
                            "name": .string(sheet.name),
                            "tables": .array(
                                sheet.tables.map {
                                    ["name": .string($0.name), "rows": .int($0.rows), "columns": .int($0.columns)]
                                }
                            ),
                        ]
                    }
                ),
            ] as Value
        }

        let (sheet, table, sizes) = try resolveNumbersTable(sheets: sheets, sheet: sheetArgument, table: tableArgument)
        let range: IWorkCellRange
        if let rangeArgument {
            range = try IWorkCellRange.parse(rangeArgument)
            guard range.fits(rows: sizes.rows, columns: sizes.columns) else {
                throw IWorkError.invalid(
                    "range is outside the table, which has \(sizes.rows) rows and \(sizes.columns) columns"
                )
            }
        } else if let leading = IWorkCellRange.leading(rows: sizes.rows, columns: sizes.columns) {
            range = leading
        } else {
            return [
                "app": "numbers", "document": .string(document), "sheet": .string(sheet), "table": .string(table),
                "rows": .int(sizes.rows), "columns": .int(sizes.columns), "values": .array([]),
            ] as Value
        }

        let result = try await runner.run(
            .numbers,
            calling: IWorkScripts.readNumbers(document: document, sheet: sheet, table: table, range: range)
        )
        let rows = IWorkResult.items(of: result).map { IWorkResult.value(from: $0) }
        return [
            "app": "numbers", "document": .string(document), "sheet": .string(sheet), "table": .string(table),
            "rows": .int(sizes.rows), "columns": .int(sizes.columns),
            "range": .string(range.text),
            "values": .array(rows),
        ] as Value
    }

    // MARK: - Numbers tables

    /// Finds the sheet and table that a request names, or the first that has a table.
    private static func resolveNumbersTable(
        sheets: [IWorkResult.NumbersSheet],
        sheet: String?,
        table: String?
    ) throws -> (sheet: String, table: String, size: (rows: Int, columns: Int)) {
        let candidates: [IWorkResult.NumbersSheet]
        if let sheet {
            candidates = sheets.filter { $0.name == sheet }
            guard !candidates.isEmpty else {
                throw IWorkError.invalid("the document has no sheet named \"\(sheet)\"")
            }
        } else {
            candidates = sheets.filter { !$0.tables.isEmpty }
        }
        guard let chosen = candidates.first else {
            throw IWorkError.invalid("the document has no tables")
        }
        let tables: [IWorkResult.NumbersTable]
        if let table {
            tables = chosen.tables.filter { $0.name == table }
            guard !tables.isEmpty else {
                throw IWorkError.invalid("the sheet \"\(chosen.name)\" has no table named \"\(table)\"")
            }
        } else {
            tables = chosen.tables
        }
        guard let found = tables.first else {
            throw IWorkError.invalid("the sheet \"\(chosen.name)\" has no tables")
        }
        return (chosen.name, found.name, (found.rows, found.columns))
    }

    private static func resolveNumbersTable(
        document: String,
        sheet: String?,
        table: String?,
        runner: any IWorkScriptRunning
    ) async throws -> (sheet: String, table: String, size: (rows: Int, columns: Int)) {
        let described = try await runner.run(.numbers, calling: IWorkScripts.describeNumbers(document: document))
        return try resolveNumbersTable(sheets: IWorkResult.numbersSheets(from: described), sheet: sheet, table: table)
    }

    // MARK: - Arguments

    private static func string(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let string = value.stringValue else {
            throw IWorkError.invalid("\(name) must be a string")
        }
        return string
    }

    private static func requiredString(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let string = try string(name, in: arguments) else {
            throw IWorkError.invalid("\(name) is required")
        }
        return string
    }

    private static func integer(_ name: String, in arguments: [String: Value], default fallback: Int) throws -> Int {
        guard let value = arguments[name], !value.isNull else { return fallback }
        guard let integer = value.intValue else {
            throw IWorkError.invalid("\(name) must be an integer")
        }
        return integer
    }

    private static func app(_ name: String, in arguments: [String: Value]) throws -> IWorkApp? {
        guard let raw = try string(name, in: arguments) else { return nil }
        guard let app = IWorkApp(rawValue: raw) else {
            let choices = IWorkApp.allCases.map(\.rawValue).joined(separator: ", ")
            throw IWorkError.invalid("\(name) must be one of: \(choices)")
        }
        return app
    }
}
