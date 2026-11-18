import Foundation
import JSONSchema
import MCP

/// The tools that find, edit, organize, export, and attach files to notes through the Notes app.
///
/// Notes are named here by the id that the Notes app gives them, such as `x-coredata://…/ICNote/p12`,
/// which `notes_create`, `notes_list_recent`, and `notes_get` return.
/// They are not the `@id` of the tools that read the database.
enum NotesOrganizeTools {
    /// The tools that change something, and so are offered only while the person allows changes.
    static let writeToolNames: Set<String> = [
        "notes_update", "notes_append", "notes_delete", "notes_move", "notes_rename_folder",
        "notes_delete_folder", "notes_batch_delete", "notes_batch_move", "notes_add_attachment",
        "notes_save_attachment",
    ]

    /// The tools that only look, which need the person's permission to use the Notes app and nothing else.
    static let readToolNames: Set<String> = [
        "notes_get", "notes_list_recent", "notes_selected", "notes_folder_tree", "notes_default_location",
        "notes_show", "notes_show_folder", "notes_list_attachments", "notes_markdown", "notes_export",
    ]

    private static let accountValue: JSONSchema =
        .string(
            description:
                "The name of the account that holds the folder, such as iCloud. Leave it out for the default account"
        )
    private static let idValue: JSONSchema =
        .string(
            description:
                "The note's id as the Notes app gives it, such as x-coredata://…/ICNote/p12, as returned by notes_create, notes_list_recent, and notes_get"
        )
    private static let changesNotice =
        "Allowed only while iMCP's Notes settings allow changes."
    private static let lossNotice =
        "Setting a note's text through Notes' scripting interface drops what that interface can't carry: checklist state, native tags, tables, and link previews. A note with attachments or a password is refused."

    static func tools(
        isEnabled: @escaping @Sendable () -> Bool,
        runner: any NotesScriptRunning
    ) -> [Tool] {
        readTools(runner: runner) + writeTools(isEnabled: isEnabled, runner: runner)
    }

    // MARK: - Reading

    static func readTools(runner: any NotesScriptRunning) -> [Tool] {
        [
            Tool(
                name: "notes_get",
                description:
                    "Read one note through the Notes app by its id: title, folder, account, dates, plain text, and a contentHash of the text. Pass the contentHash back as expectedContentHash to notes_update or notes_append so that a write is refused if the note changed. Set includeHTML for the note's HTML. A note locked with a password has no text.",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "includeHTML": .boolean(description: "Also return the note's HTML body", default: false),
                    ],
                    required: ["id"],
                    additionalProperties: false
                ),
                annotations: .init(title: "Get Note", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let note = try await fetchNote(try requiredID(in: arguments), runner: runner)
                var object = noteValue(note)
                if try bool("includeHTML", in: arguments) ?? false { object["html"] = .string(note.bodyHTML) }
                return Value.object(object)
            },

            Tool(
                name: "notes_list_recent",
                description:
                    "List the notes that changed most recently, newest first, with id, title, folder, and modified date. Notes in Recently Deleted are left out. Scan one folder, or the whole account.",
                inputSchema: .object(
                    properties: [
                        "limit": .integer(
                            description: "Maximum notes to return",
                            default: .int(20),
                            minimum: 1,
                            maximum: NotesOrganizeInput.maximumListed
                        ),
                        "folder": .string(
                            description: "A folder to list, written as Parent/Child. Leave it out for the whole account"
                        ),
                        "account": accountValue,
                    ],
                    additionalProperties: false
                ),
                annotations: .init(title: "List Recent Notes", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let limit = try NotesOrganizeInput.validatedLimit(try int("limit", in: arguments), default: 20)
                let path =
                    try string("folder", in: arguments).map(NotesFolderPath.parse) ?? NotesFolderPath(components: [])
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.listNotes(account: account, folder: path)
                )
                let recent = NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: limit)
                return summaries(recent, name: "Recent Notes")
            },

            Tool(
                name: "notes_selected",
                description:
                    "List the notes that are selected in the Notes window, with id, title, folder, and modified date.",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(title: "Get Selected Notes", readOnlyHint: true, openWorldHint: false)
            ) { _ in
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.selectedNotes
                )
                return summaries(try NotesScriptSummary.list(from: fields), name: "Selected Notes")
            },

            Tool(
                name: "notes_folder_tree",
                description: "List an account's folders as a tree, with each folder's id and how many notes it holds.",
                inputSchema: .object(properties: ["account": accountValue], additionalProperties: false),
                annotations: .init(title: "Get Note Folder Tree", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.listFolders(account: account)
                )
                let tree = NotesScriptFolder.tree(try NotesScriptFolder.list(from: fields))
                func value(_ node: NotesScriptFolder.Node) -> Value {
                    [
                        "identifier": .string(node.folder.id),
                        "name": .string(node.folder.name),
                        "account": .string(node.folder.account),
                        "noteCount": .int(node.folder.noteCount),
                        "folders": .array(node.children.map(value)),
                    ]
                }
                return [
                    "@context": "https://schema.org",
                    "@type": "ItemList",
                    "name": "Note Folders",
                    "itemListElement": .array(tree.map(value)),
                ] as Value
            },

            Tool(
                name: "notes_default_location",
                description: "Say which account and folder the Notes app puts a new note in.",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(title: "Get Default Note Location", readOnlyHint: true, openWorldHint: false)
            ) { _ in
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.defaultLocation
                )
                guard fields.count == 4 else {
                    throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
                }
                return [
                    "account": ["identifier": .string(fields[0]), "name": .string(fields[1])],
                    "folder": ["identifier": .string(fields[2]), "name": .string(fields[3])],
                ] as Value
            },

            Tool(
                name: "notes_show",
                description: "Open a note in the Notes window and bring Notes to the front.",
                inputSchema: .object(properties: ["id": idValue], required: ["id"], additionalProperties: false),
                annotations: .init(title: "Show Note", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.showNote(try requiredID(in: arguments))
                )
                return ["shown": .string(fields.first ?? ""), "name": .string(fields.dropFirst().first ?? "")] as Value
            },

            Tool(
                name: "notes_show_folder",
                description: "Open a folder in the Notes window and bring Notes to the front.",
                inputSchema: .object(
                    properties: [
                        "folder": .string(description: "The folder, written as Parent/Child"),
                        "account": accountValue,
                    ],
                    required: ["folder"],
                    additionalProperties: false
                ),
                annotations: .init(title: "Show Note Folder", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let path = try NotesOrganizeInput.requiredFolderPath(try requiredString("folder", in: arguments))
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.showFolder(account: account, folder: path)
                )
                return ["shown": .string(fields.first ?? ""), "name": .string(fields.dropFirst().first ?? "")] as Value
            },

            Tool(
                name: "notes_list_attachments",
                description:
                    "List a note's attachments through the Notes app, with id, name, content identifier, and URL.",
                inputSchema: .object(properties: ["id": idValue], required: ["id"], additionalProperties: false),
                annotations: .init(title: "List Note Attachments", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.listAttachments(try requiredID(in: arguments))
                )
                let attachments = try NotesScriptAttachment.list(from: fields)
                return [
                    "@context": "https://schema.org",
                    "@type": "ItemList",
                    "numberOfItems": .int(attachments.count),
                    "itemListElement": .array(
                        attachments.map {
                            var object: [String: Value] = ["identifier": .string($0.id), "name": .string($0.name)]
                            if !$0.contentID.isEmpty { object["contentIdentifier"] = .string($0.contentID) }
                            if !$0.url.isEmpty { object["url"] = .string($0.url) }
                            if let created = NotesDates.iso($0.created) { object["dateCreated"] = .string(created) }
                            return .object(object)
                        }
                    ),
                ] as Value
            },

            Tool(
                name: "notes_markdown",
                description:
                    "Read one note as Markdown, converted from the HTML that the Notes app reports: headings, bold, italic, links, lists, and tables. Checklist state, native tags, and drawings aren't in that HTML; notes_read has them.",
                inputSchema: .object(properties: ["id": idValue], required: ["id"], additionalProperties: false),
                annotations: .init(title: "Get Note as Markdown", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let note = try await fetchNote(try requiredID(in: arguments), runner: runner)
                var object = noteValue(note)
                object["encodingFormat"] = "text/markdown"
                object["text"] = .string(NotesExporter.markdown(NotesExportItem(note)))
                return Value.object(object)
            },

            Tool(
                name: "notes_export",
                description:
                    "Export notes as JSON, Markdown, or HTML, returned as text. Name the notes by id, or give a folder to export its notes, newest first. Markdown notes start with front matter; JSON keeps each note's HTML and plain text.",
                inputSchema: .object(
                    properties: [
                        "format": .string(
                            description: "The export format",
                            enum: NotesExportFormat.allCases.map { .string($0.rawValue) }
                        ),
                        "ids": .array(
                            description: "Notes to export, by id, at most \(NotesOrganizeInput.maximumBatch)",
                            items: .string()
                        ),
                        "folder": .string(description: "A folder to export, written as Parent/Child, in place of ids"),
                        "account": accountValue,
                        "limit": .integer(
                            description: "The most notes to export from a folder",
                            default: .int(25),
                            minimum: 1,
                            maximum: NotesOrganizeInput.maximumBatch
                        ),
                    ],
                    required: ["format"],
                    additionalProperties: false
                ),
                annotations: .init(title: "Export Notes", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                guard let name = try string("format", in: arguments), let format = NotesExportFormat(rawValue: name)
                else {
                    let choices = NotesExportFormat.allCases.map(\.rawValue).joined(separator: ", ")
                    throw NotesWriteError.invalid("format must be one of: \(choices)")
                }
                var ids: [String]
                if let given = try strings("ids", in: arguments) {
                    ids = try NotesOrganizeInput.validatedNoteIDs(given)
                } else if let folder = try string("folder", in: arguments) {
                    let path = try NotesOrganizeInput.requiredFolderPath(folder)
                    let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                    let limit = min(try int("limit", in: arguments) ?? 25, NotesOrganizeInput.maximumBatch)
                    let fields = try await runner.run(
                        NotesOrganizeScripts.source,
                        calling: NotesOrganizeScripts.listNotes(account: account, folder: path)
                    )
                    ids = NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: limit).map(\.id)
                } else {
                    throw NotesWriteError.invalid("give ids or a folder")
                }
                var items: [NotesExportItem] = []
                for id in ids { items.append(NotesExportItem(try await fetchNote(id, runner: runner))) }
                return [
                    "format": .string(format.rawValue),
                    "numberOfItems": .int(items.count),
                    "text": .string(try NotesExporter.export(items, as: format)),
                ] as Value
            },
        ]
    }

    // MARK: - Changing

    static func writeTools(
        isEnabled: @escaping @Sendable () -> Bool,
        runner: any NotesScriptRunning
    ) -> [Tool] {
        let formatValue: JSONSchema =
            .string(
                description:
                    "How the text is written: plaintext shows it as written, markdown converts it, and html passes it to Notes as HTML",
                default: .string(NotesContentFormat.plaintext.rawValue),
                enum: NotesContentFormat.allCases.map { .string($0.rawValue) }
            )
        let hashValue: JSONSchema =
            .string(description: "The contentHash that notes_get returned for the text that you are changing")
        return [
            Tool(
                name: "notes_update",
                description:
                    "Replace a note's text. It is refused unless expectedContentHash is the contentHash of the note's current text, so an edit never overwrites a newer one. The title becomes the first line, and the body follows it. \(lossNotice) \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "expectedContentHash": hashValue,
                        "body": .string(
                            description:
                                "The note's new contents, in the given format, up to \(NotesWriteInput.maximumBodyLength) characters"
                        ),
                        "title": .string(description: "The note's new title. Leave it out to keep the current title"),
                        "format": formatValue,
                    ],
                    required: ["id", "expectedContentHash", "body"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Update Note",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                let note = try await fetchNote(id, runner: runner)
                try NotesContentHash.requireCurrent(
                    note,
                    expected: try requiredString("expectedContentHash", in: arguments)
                )
                let request = try NotesNoteRequest(
                    title: try string("title", in: arguments) ?? note.title,
                    body: try requiredString("body", in: arguments),
                    format: try format(in: arguments),
                    folder: nil,
                    account: nil,
                    createMissingFolders: false
                )
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.updateNote(
                        id: id,
                        expectedPlainText: note.plainText,
                        bodyHTML: request.bodyHTML
                    )
                )
                return try writeResult(fields)
            },

            Tool(
                name: "notes_append",
                description:
                    "Add text to the end of a note. Pass expectedContentHash to refuse the write when the note has changed since it was read. \(lossNotice) \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "text": .string(
                            description:
                                "The text to add, in the given format, up to \(NotesWriteInput.maximumBodyLength) characters"
                        ),
                        "format": formatValue,
                        "expectedContentHash": hashValue,
                    ],
                    required: ["id", "text"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Append to Note",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                let text = try NotesWriteInput.validatedBody(try requiredString("text", in: arguments))
                let html =
                    switch try format(in: arguments) {
                    case .plaintext: NotesHTML.html(fromPlainText: text)
                    case .html: text
                    case .markdown: NotesMarkdown.html(from: text)
                    }
                var expected: String?
                if let hash = try string("expectedContentHash", in: arguments) {
                    let note = try await fetchNote(id, runner: runner)
                    try NotesContentHash.requireCurrent(note, expected: hash)
                    expected = note.plainText
                }
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.appendToNote(id: id, expectedPlainText: expected, additionHTML: html)
                )
                return try writeResult(fields)
            },

            Tool(
                name: "notes_delete",
                description:
                    "Move a note to Recently Deleted in the Notes app, from which it can be restored for about 30 days. Nothing is erased for good. \(changesNotice)",
                inputSchema: .object(properties: ["id": idValue], required: ["id"], additionalProperties: false),
                annotations: .init(
                    title: "Delete Note",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.deleteNote(id)
                )
                return ["deleted": .string(id), "name": .string(fields.dropFirst().first ?? "")] as Value
            },

            Tool(
                name: "notes_move",
                description:
                    "Move a note into a folder that exists. The note's id can change when it moves to another account, so use the id in the result. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "folder": .string(description: "The destination folder, written as Parent/Child"),
                        "account": accountValue,
                    ],
                    required: ["id", "folder"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Move Note",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                let path = try NotesOrganizeInput.requiredFolderPath(try requiredString("folder", in: arguments))
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.moveNote(id: id, account: account, folder: path)
                )
                guard fields.count >= 3 else {
                    throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
                }
                return ["identifier": .string(fields[0]), "name": .string(fields[1]), "folder": .string(fields[2])]
                    as Value
            },

            Tool(
                name: "notes_rename_folder",
                description:
                    "Rename a folder in the Notes app. It is an error if a folder beside it has the new name. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "folder": .string(description: "The folder, written as Parent/Child"),
                        "newName": .string(
                            description:
                                "The new name, up to \(NotesFolderPath.maximumNameLength) characters, without \"/\""
                        ),
                        "account": accountValue,
                    ],
                    required: ["folder", "newName"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Rename Note Folder",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let path = try NotesOrganizeInput.requiredFolderPath(try requiredString("folder", in: arguments))
                let newName = try NotesWriteInput.validatedFolderName(try requiredString("newName", in: arguments))
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.renameFolder(account: account, folder: path, newName: newName)
                )
                return ["identifier": .string(fields.first ?? ""), "name": .string(fields.dropFirst().first ?? "")]
                    as Value
            },

            Tool(
                name: "notes_delete_folder",
                description:
                    "Delete a folder in the Notes app. A folder that holds notes or folders is refused unless deleteContents is true, and then its notes go to Recently Deleted with it. An account's default folder is never deleted. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "folder": .string(description: "The folder, written as Parent/Child"),
                        "deleteContents": .boolean(
                            description: "Delete the folder even though it holds notes or folders",
                            default: false
                        ),
                        "account": accountValue,
                    ],
                    required: ["folder"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Delete Note Folder",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let path = try NotesOrganizeInput.requiredFolderPath(try requiredString("folder", in: arguments))
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                let contents = try bool("deleteContents", in: arguments) ?? false
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.deleteFolder(account: account, folder: path, deleteContents: contents)
                )
                guard fields.count >= 4 else {
                    throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
                }
                return [
                    "deleted": .string(fields[0]), "name": .string(fields[1]),
                    "notes": .int(Int(fields[2]) ?? 0), "folders": .int(Int(fields[3]) ?? 0),
                ] as Value
            },

            Tool(
                name: "notes_batch_delete",
                description:
                    "Move up to \(NotesOrganizeInput.maximumBatch) notes to Recently Deleted. Each note has its own result, so one that fails doesn't stop the others. \(changesNotice)",
                inputSchema: .object(
                    properties: ["ids": .array(description: "The notes' ids", items: .string())],
                    required: ["ids"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Delete Notes",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let ids = try NotesOrganizeInput.validatedNoteIDs(try strings("ids", in: arguments) ?? [])
                var results: [Value] = []
                for id in ids {
                    do {
                        _ = try await runner.run(
                            NotesOrganizeScripts.source,
                            calling: NotesOrganizeScripts.deleteNote(id)
                        )
                        results.append(["id": .string(id), "ok": true])
                    } catch {
                        results.append(["id": .string(id), "ok": false, "error": .string(error.localizedDescription)])
                    }
                }
                return batch(results)
            },

            Tool(
                name: "notes_batch_move",
                description:
                    "Move up to \(NotesOrganizeInput.maximumBatch) notes into a folder that exists. Each note has its own result. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "ids": .array(description: "The notes' ids", items: .string()),
                        "folder": .string(description: "The destination folder, written as Parent/Child"),
                        "account": accountValue,
                    ],
                    required: ["ids", "folder"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Move Notes",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let ids = try NotesOrganizeInput.validatedNoteIDs(try strings("ids", in: arguments) ?? [])
                let path = try NotesOrganizeInput.requiredFolderPath(try requiredString("folder", in: arguments))
                let account = try string("account", in: arguments).map(NotesWriteInput.validatedAccount)
                var results: [Value] = []
                for id in ids {
                    do {
                        let fields = try await runner.run(
                            NotesOrganizeScripts.source,
                            calling: NotesOrganizeScripts.moveNote(id: id, account: account, folder: path)
                        )
                        results.append(["id": .string(id), "ok": true, "newId": .string(fields.first ?? id)])
                    } catch {
                        results.append(["id": .string(id), "ok": false, "error": .string(error.localizedDescription)])
                    }
                }
                return batch(results)
            },

            Tool(
                name: "notes_add_attachment",
                description:
                    "Attach a file to the end of a note. Give the absolute path of a file that the Notes app can read, or the file's contents as base64 with its name. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "path": .string(description: "The absolute path of the file to attach"),
                        "base64": .string(description: "The file's contents, base64 encoded, in place of path"),
                        "filename": .string(description: "The file's name, with its extension, for base64 contents"),
                    ],
                    required: ["id"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Add Note Attachment",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                var path: String
                var cleanup: URL?
                if let given = try string("path", in: arguments) {
                    path = try NotesOrganizeInput.validatedPath(given, called: "path")
                } else if let encoded = try string("base64", in: arguments) {
                    let staged = try NotesAttachmentStaging.stage(
                        base64: encoded,
                        filename: try requiredString("filename", in: arguments)
                    )
                    path = staged.path
                    cleanup = staged.deletingLastPathComponent()
                } else {
                    throw NotesWriteError.invalid("give path or base64")
                }
                defer { cleanup.map { try? FileManager.default.removeItem(at: $0) } }
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.addAttachment(id: id, path: path)
                )
                return [
                    "identifier": .string(fields.first ?? ""), "name": .string(fields.dropFirst().first ?? ""),
                    "note": .string(id),
                ] as Value
            },

            Tool(
                name: "notes_save_attachment",
                description:
                    "Have the Notes app save one of a note's attachments to a file at an absolute path that Notes can write. List the attachment ids with notes_list_attachments. \(changesNotice)",
                inputSchema: .object(
                    properties: [
                        "id": idValue,
                        "attachmentId": .string(description: "The attachment's id, from notes_list_attachments"),
                        "path": .string(description: "The absolute path of the file to write"),
                    ],
                    required: ["id", "attachmentId", "path"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Save Note Attachment",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try NotesWriteTools.requireEnabled(isEnabled())
                let id = try requiredID(in: arguments)
                let attachment = try requiredString("attachmentId", in: arguments)
                let path = try NotesOrganizeInput.validatedPath(
                    try requiredString("path", in: arguments),
                    called: "path"
                )
                guard !FileManager.default.fileExists(atPath: path) else {
                    throw NotesWriteError.invalid("a file already exists at path")
                }
                let fields = try await runner.run(
                    NotesOrganizeScripts.source,
                    calling: NotesOrganizeScripts.saveAttachment(id: id, attachmentID: attachment, path: path)
                )
                return ["saved": .string(path), "name": .string(fields.dropFirst().first ?? "")] as Value
            },
        ]
    }

    // MARK: - Results

    static func fetchNote(_ id: String, runner: any NotesScriptRunning) async throws -> NotesScriptNote {
        let fields = try await runner.run(NotesOrganizeScripts.source, calling: NotesOrganizeScripts.getNote(id))
        return try NotesScriptNote(fields: fields)
    }

    static func noteValue(_ note: NotesScriptNote) -> [String: Value] {
        var object: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "NoteDigitalDocument",
            "identifier": .string(note.id),
            "name": .string(note.title),
            "folder": .string(note.folder),
            "folderIdentifier": .string(note.folderID),
            "account": .string(note.account),
            "locked": .bool(note.isPasswordProtected),
            "shared": .bool(note.isShared),
            "attachmentCount": .int(note.attachmentCount),
        ]
        if let created = NotesDates.iso(note.created) { object["dateCreated"] = .string(created) }
        if let modified = NotesDates.iso(note.modified) { object["dateModified"] = .string(modified) }
        if !note.isPasswordProtected {
            object["text"] = .string(note.plainText)
            object["contentHash"] = .string(note.contentHash)
        }
        return object
    }

    private static func summaries(_ notes: [NotesScriptSummary], name: String) -> Value {
        [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": .string(name),
            "numberOfItems": .int(notes.count),
            "itemListElement": .array(
                notes.map { note in
                    var object: [String: Value] = [
                        "@type": "NoteDigitalDocument",
                        "identifier": .string(note.id),
                        "name": .string(note.title),
                        "folder": .string(note.folder),
                    ]
                    if let modified = NotesDates.iso(note.modified) { object["dateModified"] = .string(modified) }
                    return .object(object)
                }
            ),
        ]
    }

    private static func batch(_ results: [Value]) -> Value {
        let failed = results.filter { $0.objectValue?["ok"]?.boolValue == false }.count
        return [
            "succeeded": .int(results.count - failed), "failed": .int(failed), "results": .array(results),
        ] as Value
    }

    private static func writeResult(_ fields: [String]) throws -> Value {
        guard fields.count >= 3 else { throw NotesWriteError.scriptFailed("Notes returned an unexpected answer") }
        return [
            "identifier": .string(fields[0]), "name": .string(fields[1]),
            "dateModified": .string(NotesDates.iso(NotesDates.date(fromLocalISO: fields[2])) ?? fields[2]),
        ] as Value
    }

    // MARK: - Arguments

    private static func requiredID(in arguments: [String: Value]) throws -> String {
        try NotesOrganizeInput.validatedNoteID(try requiredString("id", in: arguments))
    }

    private static func string(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw NotesWriteError.invalid("\(name) must be a string") }
        return string
    }

    private static func requiredString(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let string = try string(name, in: arguments) else { throw NotesWriteError.invalid("\(name) is required") }
        return string
    }

    private static func bool(_ name: String, in arguments: [String: Value]) throws -> Bool? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let bool = value.boolValue else { throw NotesWriteError.invalid("\(name) must be true or false") }
        return bool
    }

    private static func int(_ name: String, in arguments: [String: Value]) throws -> Int? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let int = value.intValue else { throw NotesWriteError.invalid("\(name) must be a whole number") }
        return int
    }

    private static func strings(_ name: String, in arguments: [String: Value]) throws -> [String]? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let array = value.arrayValue else { throw NotesWriteError.invalid("\(name) must be a list of strings") }
        return try array.map {
            guard let string = $0.stringValue else {
                throw NotesWriteError.invalid("\(name) must be a list of strings")
            }
            return string
        }
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

/// Writes the contents of an attachment to a file that the Notes app can then read.
enum NotesAttachmentStaging {
    static let maximumBytes = 25 * 1024 * 1024

    /// A file name with no folders in it, or throws.
    static func safeFilename(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
            !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw NotesWriteError.invalid("filename must be a file name without folders")
        }
        return name
    }

    /// Decodes `base64` into a new file named `filename` in a new temporary folder, and returns the file.
    static func stage(base64: String, filename: String) throws -> URL {
        let filename = try safeFilename(filename)
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw NotesWriteError.invalid("base64 isn't valid base64")
        }
        guard data.count <= maximumBytes else {
            throw NotesWriteError.invalid("the file can have at most \(maximumBytes / 1024 / 1024) MB")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "imcp-notes-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(filename)
        try data.write(to: file)
        return file
    }
}
