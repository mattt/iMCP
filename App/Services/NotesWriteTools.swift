import Foundation
import MCP

/// Runs the script that changes the Notes app.
///
/// The Notes service uses the Notes app through `NSAppleScript`;
/// tests use a stand-in that sends nothing.
protocol NotesScriptRunning: Sendable {
    /// Runs `subroutine` of the script `source`, and returns the strings of the list that it returns.
    func run(_ source: String, calling subroutine: NSAppleScript.Subroutine) async throws -> [String]
}

/// Runs the script in the Notes app, which asks the person to allow it the first time.
struct AppleNotesScriptRunner: NotesScriptRunning {
    func run(_ source: String, calling subroutine: NSAppleScript.Subroutine) async throws -> [String] {
        do {
            let result = try await NSAppleScript.execute(source, calling: subroutine)
            guard result.descriptorType == typeAEList else { return [] }
            return (0 ..< result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }
        } catch let error as NSAppleScript.ExecutionError {
            if error.number == Int(errAEEventNotPermitted) {
                throw NotesWriteError.automationDenied
            }
            throw NotesWriteError.scriptFailed(error.message)
        }
    }
}

/// Finds the Notes database's identifiers of what the script made,
/// because the scripting interface's identifiers are not the ones the read tools take.
protocol NotesIdentifierResolving: Sendable {
    /// The identifier of the one note that was just made, or `nil` if it can't be told.
    func noteID(
        title: String,
        folderPath: [String],
        folderName: String,
        accountName: String,
        createdAfter date: Date
    ) async -> String?
    /// The identifier of the one folder that was just made, or `nil` if it can't be told.
    func folderID(path: [String], accountName: String) async -> String?
}

/// Resolves nothing, for a service that can't read the database.
struct NoIdentifierResolver: NotesIdentifierResolving {
    func noteID(
        title: String,
        folderPath: [String],
        folderName: String,
        accountName: String,
        createdAfter date: Date
    ) async -> String? { nil }
    func folderID(path: [String], accountName: String) async -> String? { nil }
}

/// The tools that create notes and folders.
///
/// They only add to the Notes app: nothing they do changes or removes what is already there.
/// The Notes service's "Allow writes" setting decides whether clients are offered them (see `NotesService.writesEnabledByDefault`).
enum NotesWriteTools {
    static let toolNames: Set<String> = ["notes_create", "notes_create_folder"]

    /// The tools. They run only while the service's "Allow writes" setting is on, which `Service.call` checks.
    static func tools(
        runner: any NotesScriptRunning,
        resolver: any NotesIdentifierResolving = NoIdentifierResolver()
    ) -> [Tool] {
        [
            Tool(
                name: "notes_create",
                description:
                    "Create a note in the Notes app. The title becomes the note's first line, and the body follows it. The note goes in the account's default folder unless a folder is given. Creating a note never changes existing notes. The result's identifier, when present, is the note's id for the read tools; scriptIdentifier is the Notes scripting id and can't be passed to them. Notes keeps less than Markdown can say: a link becomes its text followed by its address, a checklist becomes bullets that start with ☐ or ☑, and a numbered list becomes lines that start with their numbers. Available only while \"Allow writes\" is on for Notes in iMCP's settings.",
                inputSchema: .object(
                    properties: [
                        "title": .string(
                            description:
                                "The note's title, on one line, up to \(NotesWriteInput.maximumTitleLength) characters"
                        ),
                        "body": .string(
                            description:
                                "The note's contents, written in the given format, up to \(NotesWriteInput.maximumBodyLength) characters. Leave it out for a note with only a title"
                        ),
                        "format": .string(
                            description:
                                "How the body is written: plaintext shows it as written, and markdown converts it",
                            default: .string(NotesContentFormat.plaintext.rawValue),
                            enum: NotesContentFormat.allCases.map { .string($0.rawValue) }
                        ),
                        "folder": .string(
                            description:
                                "The folder for the note, written as Parent/Child for a folder inside another. Folder names can't contain \"/\". Leave it out for the account's default folder"
                        ),
                        "account": .string(
                            description:
                                "The name of the account that holds the folder, such as iCloud. Leave it out for the default account"
                        ),
                        "createMissingFolders": .boolean(
                            description:
                                "Create the folders of the path that don't exist. Without this, a folder that doesn't exist is an error",
                            default: false
                        ),
                    ],
                    required: ["title"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Create Note",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                let request = try NotesNoteRequest(
                    title: try requiredString("title", in: arguments),
                    body: try string("body", in: arguments) ?? "",
                    format: try format(in: arguments),
                    folder: try string("folder", in: arguments),
                    account: try string("account", in: arguments),
                    createMissingFolders: try bool("createMissingFolders", in: arguments) ?? false
                )
                // The database's creation date can differ a little from this clock.
                let startedAt = Date().addingTimeInterval(-10)
                let result = try await runner.run(NotesScripts.source, calling: NotesScripts.createNote(request))
                guard result.count >= 4 else {
                    throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
                }
                var object: [String: Value] = [
                    "@context": "https://schema.org",
                    "@type": "NoteDigitalDocument",
                    "scriptIdentifier": .string(result[0]),
                    "name": .string(result[1]),
                    "folder": .string(result[2]),
                    "account": .string(result[3]),
                ]
                if let id = await resolver.noteID(
                    title: request.title,
                    folderPath: request.folder.components,
                    folderName: result[2],
                    accountName: result[3],
                    createdAfter: startedAt
                ) {
                    object["identifier"] = .string(id)
                } else {
                    object["description"] = .string(Self.unresolvedNote)
                }
                return Value.object(object)
            },

            Tool(
                name: "notes_create_folder",
                description:
                    "Create a folder in the Notes app, at the top level of an account or inside a folder that exists. It is an error if the parent already has a folder with that name. The result's identifier, when present, is the folder's id for the read tools; scriptIdentifier is the Notes scripting id and can't be passed to them. Available only while \"Allow writes\" is on for Notes in iMCP's settings.",
                inputSchema: .object(
                    properties: [
                        "name": .string(
                            description:
                                "The new folder's name, up to \(NotesFolderPath.maximumNameLength) characters, without \"/\""
                        ),
                        "parent": .string(
                            description:
                                "The folder that holds the new one, written as Parent/Child for a folder inside another. It must exist. Leave it out for the top level of the account"
                        ),
                        "account": .string(
                            description:
                                "The name of the account that holds the folder, such as iCloud. Leave it out for the default account"
                        ),
                    ],
                    required: ["name"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Create Note Folder",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                let request = try NotesFolderRequest(
                    name: try requiredString("name", in: arguments),
                    parent: try string("parent", in: arguments),
                    account: try string("account", in: arguments)
                )
                let result = try await runner.run(NotesScripts.source, calling: NotesScripts.createFolder(request))
                guard result.count >= 3 else {
                    throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
                }
                var object: [String: Value] = [
                    "@context": "https://schema.org",
                    "@type": "Collection",
                    "scriptIdentifier": .string(result[0]),
                    "name": .string(result[1]),
                    "account": .string(result[2]),
                ]
                if let id = await resolver.folderID(
                    path: request.parent.components + [request.name],
                    accountName: result[2]
                ) {
                    object["identifier"] = .string(id)
                } else {
                    object["description"] = .string(Self.unresolvedFolder)
                }
                return Value.object(object)
            },
        ]
    }

    private static let unresolvedNote =
        "The note was created. Its id for the read tools could not be found in the Notes database yet; use notes_fetch to find it."
    private static let unresolvedFolder =
        "The folder was created. Its id for the read tools could not be found in the Notes database yet; use notes_folders to find it."

    // MARK: - Arguments

    private static func string(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let string = value.stringValue else {
            throw NotesWriteError.invalid("\(name) must be a string")
        }
        return string
    }

    private static func requiredString(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let string = try string(name, in: arguments) else {
            throw NotesWriteError.invalid("\(name) is required")
        }
        return string
    }

    private static func bool(_ name: String, in arguments: [String: Value]) throws -> Bool? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let bool = value.boolValue else {
            throw NotesWriteError.invalid("\(name) must be true or false")
        }
        return bool
    }

    private static func format(in arguments: [String: Value]) throws -> NotesContentFormat {
        guard let name = try string("format", in: arguments) else { return .plaintext }
        guard let format = NotesContentFormat(rawValue: name) else {
            let choices = NotesContentFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw NotesWriteError.invalid("format must be one of: \(choices)")
        }
        return format
    }
}
