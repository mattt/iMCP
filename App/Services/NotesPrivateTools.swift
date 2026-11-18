import Foundation
import JSONSchema
import MCP
import OrderedCollections

/// The private Notes tools, built on Apple's unsupported NotesShared framework.
/// They are off until "Private Notes features" is turned on in iMCP Settings, and the ones that
/// change a note also need "Allow iMCP to change notes and folders".
/// Note ids are the ones the other Notes tools return (`x-coredata://…/ICNote/pN`).
enum NotesPrivateTools {
    private static let idHelp =
        "Note id from notes_get, notes_list_recent, notes_fetch, or notes_create (x-coredata://…/ICNote/pN), or the note's UUID"

    private static func make(
        name: String,
        title: String,
        description: String,
        properties: OrderedDictionary<String, JSONSchema>,
        required: [String] = [],
        readOnly: Bool = false,
        destructive: Bool = false
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object(
                properties: properties,
                required: required,
                additionalProperties: false
            ),
            annotations: .init(
                title: title,
                readOnlyHint: readOnly,
                destructiveHint: destructive,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let plain = try NotesPrivateArguments.plain(arguments)
            let result = try await NotesPrivate.run(tool: name, arguments: plain)
            return try NotesPrivateArguments.value(result)
        }
    }

    private static func actions(_ names: [String]) -> JSONSchema {
        .string(description: "What to do", enum: names.map { .string($0) })
    }

    /// The tools, for the Notes service to append to its own.
    static var tools: [Tool] {
        [structure, tags, pin, checklist, table, link, appendRich, createMarkdown]
    }

    static var structure: Tool {
        make(
            name: "notes_structure",
            title: "Read Note Structure",
            description:
                "Read a note's native structure from Notes itself: pinned state, native tags, checklist items with their done state, tables with their cells, links to other notes, and (with blocks) every paragraph with its style (title, heading, subheading, body, monospaced, bulleted, dashed, numbered, checklist). Also returns the note's notes:// link. Password protected notes are refused. Requires Private Notes features.",
            properties: [
                "id": .string(description: idHelp),
                "blocks": .boolean(description: "Also return every paragraph as a typed block", default: false),
            ],
            required: ["id"],
            readOnly: true
        )
    }

    static var tags: Tool {
        make(
            name: "notes_native_tags",
            title: "Native Note Tags",
            description:
                "Read or change a note's real native tags (the tag chips Notes keeps, not plain #text). Actions: list (the tags of one note with id, the tags used in a folder with folder, or the account-wide inventory with neither), add, remove (only that note's tags; tag definitions stay), and replace (ids or id, old, new: adds the new tag, reads it back, then removes the old one). Tags are single words with or without a leading #. Changes are verified by reading the tags back. Changes need Allow iMCP to change notes and folders.",
            properties: [
                "action": actions(["list", "add", "remove", "replace"]),
                "id": .string(description: idHelp),
                "ids": .array(description: "Notes to change, for replace (up to 100)", items: .string()),
                "folder": .string(description: "Folder, written as Parent/Child, for list"),
                "account": .string(description: "Account name, to choose among folders with the same name"),
                "tags": .array(description: "Tag names for add and remove", items: .string()),
                "old": .string(description: "Tag to remove, for replace"),
                "new": .string(description: "Tag to add, for replace"),
            ],
            required: ["action"]
        )
    }

    static var pin: Tool {
        make(
            name: "notes_pin",
            title: "Pin or Unpin Note",
            description:
                "Pin a note to the top of its list or unpin it, without touching its text. Pass expected_pinned to refuse the change if the note is not in the state you last saw. Verified by reading the state back. Needs Allow iMCP to change notes and folders.",
            properties: [
                "id": .string(description: idHelp),
                "pinned": .boolean(description: "true to pin, false to unpin"),
                "expected_pinned": .boolean(
                    description: "The pinned state you last read; the call is refused if it differs"
                ),
            ],
            required: ["id", "pinned"]
        )
    }

    static var checklist: Tool {
        make(
            name: "notes_checklist",
            title: "Note Checklist",
            description:
                "Work with a note's real checklist items (the tappable circles in Notes). Actions: get (every item with its done state), add (append 1 to 20 one-line items at the end; existing text and styles are untouched), and set (mark one item done or not done, chosen by index from 0 or by its exact text). Verified by reading the checklist back. add and set need Allow iMCP to change notes and folders.",
            properties: [
                "action": actions(["get", "add", "set"]),
                "id": .string(description: idHelp),
                "items": .array(description: "One-line item texts, for add", items: .string()),
                "done": .boolean(
                    description: "For add, whether the new items start done (default false). For set, the state to set"
                ),
                "index": .integer(description: "Checklist item number counted from 0, for set"),
                "text": .string(description: "Exact item text, for set, when index is not used"),
            ],
            required: ["action", "id"]
        )
    }

    static var table: Tool {
        make(
            name: "notes_table",
            title: "Note Table",
            description:
                "Work with a note's native tables. Actions: get (every table with its cells) and create (append a native table from rectangular rows of one-line strings, 1 to 1000 rows of 1 to 100 cells). Verified by reading every cell back. create needs Allow iMCP to change notes and folders.",
            properties: [
                "action": actions(["get", "create"]),
                "id": .string(description: idHelp),
                "rows": .array(
                    description: "Cell text, row by row; every row the same length; no tabs or line breaks",
                    items: .array(items: .string())
                ),
            ],
            required: ["action", "id"]
        )
    }

    static var link: Tool {
        make(
            name: "notes_link",
            title: "Note Links",
            description:
                "Links between notes. Actions: get (the note's real notes://showNote link, which opens it in Notes on Mac and iPhone), list (the links to other notes inside a note), and insert (append a native link chip to another note at the end of the note; label sets the visible text). insert is verified by reading the link target back and needs Allow iMCP to change notes and folders.",
            properties: [
                "action": actions(["get", "list", "insert"]),
                "id": .string(description: idHelp),
                "target": .string(description: "The note to link to, for insert. Same forms as id"),
                "label": .string(description: "Visible text of the link, for insert (default: the target's title)"),
            ],
            required: ["action", "id"]
        )
    }

    static var appendRich: Tool {
        make(
            name: "notes_append_rich",
            title: "Append to Note Without Rewriting It",
            description:
                "Append text to the end of a note through Notes' own editor, so existing checklists, tags, tables, links, and attachments are kept (notes_append rewrites the whole body). format markdown uses Notes' native Markdown importer: headings, lists, checklists, bold and italic. Verified by reading back that the old text is intact and the new text is present. Needs Allow iMCP to change notes and folders.",
            properties: [
                "id": .string(description: idHelp),
                "content": .string(description: "The text to append"),
                "format": .string(
                    description: "plaintext (default) or markdown",
                    default: .string("plaintext"),
                    enum: [.string("plaintext"), .string("markdown")]
                ),
            ],
            required: ["id", "content"]
        )
    }

    static var createMarkdown: Tool {
        make(
            name: "notes_create_markdown",
            title: "Create Note From Markdown",
            description:
                "Create a note from Markdown with Notes' own native importer: # becomes the note's title and headings, - [ ] becomes a real checklist, bold and italic are kept. title adds a first heading when the Markdown has none. The note goes in the given folder (Parent/Child) or the account's default folder. Verified by reading the new note back. Needs Allow iMCP to change notes and folders.",
            properties: [
                "markdown": .string(description: "The note's Markdown"),
                "title": .string(
                    description: "Title, used as a first heading when the Markdown does not start with one"
                ),
                "folder": .string(description: "Folder, written as Parent/Child. Leave out for the default folder"),
                "account": .string(
                    description:
                        "Account name, to choose among folders with the same name or the account for the default folder"
                ),
            ],
            required: ["markdown"]
        )
    }
}

/// MCP arguments as plain JSON values, which is what the pure layer validates.
enum NotesPrivateArguments {
    static func plain(_ arguments: [String: Value]) throws -> [String: Any] {
        let data = try JSONEncoder().encode(arguments)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// A result as an MCP value.
    static func value(_ object: [String: Any]) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
