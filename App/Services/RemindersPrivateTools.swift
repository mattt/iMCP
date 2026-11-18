import Foundation
import JSONSchema
import MCP
import OrderedCollections

/// The private Reminders tools, built on Apple's unsupported ReminderKit framework.
/// They are off until "Private Reminders features" is turned on in iMCP Settings.
/// Identifiers are the ones the other Reminders tools return (`calendarItemIdentifier`
/// and `calendarIdentifier`), which are the same UUIDs ReminderKit uses.
enum RemindersPrivateTools {
    private static let idHelp =
        "Reminder identifier from reminders_fetch, reminders_get, or reminders_create"

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
            let plain = try plainArguments(arguments)
            let result = try await RemindersPrivate.run(tool: name, arguments: plain)
            return try Value(jsonObject: result)
        }
    }

    /// MCP arguments as plain JSON values, which is what the pure layer validates.
    static func plainArguments(_ arguments: [String: Value]) throws -> [String: Any] {
        let data = try JSONEncoder().encode(arguments)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func actions(_ names: [String]) -> JSONSchema {
        .string(description: "What to do", enum: names.map { .string($0) })
    }

    static var tags: Tool {
        make(
            name: "reminders_tags",
            title: "Reminder Tags",
            description:
                "Read or change a reminder's real synced tags (not hashtags in the title). Actions: add (keeps existing tags), set (replaces the tag set), remove, clear, and list (the tags in use in a list, with counts). Tags are single words, with or without a leading #. Verified by reading the tags back.",
            properties: [
                "action": actions(["list", "add", "set", "remove", "clear"]),
                "id": .string(description: idHelp),
                "tags": .array(description: "Tag names for add, set, and remove", items: .string()),
                "list": .string(description: "List name, for action list"),
                "list_id": .string(description: "List identifier, for action list"),
            ],
            required: ["action"]
        )
    }

    static var addLink: Tool {
        make(
            name: "reminders_add_link",
            title: "Add Reminder Rich Link",
            description:
                "Attach a rich link to a reminder: a public http or https page, or an app link such as obsidian://open?vault=Notes&file=Plan. Additive; existing links stay. Local, private, and file-server addresses are refused. Verified by reading the links back.",
            properties: [
                "id": .string(description: idHelp),
                "url": .string(description: "The link", format: .uri),
            ],
            required: ["id", "url"]
        )
    }

    static var flag: Tool {
        make(
            name: "reminders_flag",
            title: "Flag or Mark Urgent",
            description:
                "Flag or unflag a reminder, and turn its urgent state on or off. Pass flagged, urgent, or both. Verified by reading the state back.",
            properties: [
                "id": .string(description: idHelp),
                "flagged": .boolean(description: "Flag (true) or unflag (false)"),
                "urgent": .boolean(description: "Mark urgent (true) or not (false)"),
            ],
            required: ["id"]
        )
    }

    static var getPrivate: Tool {
        make(
            name: "reminders_get_private",
            title: "Get Reminder Private Details",
            description:
                "Read what EventKit cannot: a reminder's tags, rich links, flag, urgent state, section, and parent reminder.",
            properties: ["id": .string(description: idHelp)],
            required: ["id"],
            readOnly: true
        )
    }

    static var sections: Tool {
        make(
            name: "reminders_sections",
            title: "Reminder Sections",
            description:
                "Manage a list's sections. Actions: list, create (name), rename (section or section_id, then name), delete (reminders in it move out, they are not deleted), and assign (put a reminder, by id, in a section; taking one out of a section is not supported). Pick a list by list (name) or list_id, and a section by section (name) or section_id; a duplicate name is refused with the ids to choose from.",
            properties: [
                "action": actions(["list", "create", "rename", "delete", "assign"]),
                "list": .string(description: "List name"),
                "list_id": .string(description: "List identifier"),
                "section": .string(description: "Section name"),
                "section_id": .string(description: "Section identifier from action list"),
                "name": .string(description: "New section name, for create and rename"),
                "id": .string(description: "Reminder identifier, for assign"),
            ],
            required: ["action"],
            destructive: true
        )
    }

    static var subtasks: Tool {
        make(
            name: "reminders_subtasks",
            title: "Reminder Subtasks",
            description:
                "Create subtasks and move reminders between levels. Actions: create (parent_id, title), list (parent_id), and move (id, then parent_id to nest it, or top_level true to make it a top-level reminder). The reminder keeps its identifier; nothing is cloned. Reminders allows one level, so a parent cannot itself be a subtask, a reminder with subtasks cannot be nested, and a parent must be in the same list.",
            properties: [
                "action": actions(["create", "list", "move"]),
                "id": .string(description: "Reminder to move"),
                "parent_id": .string(description: "Parent reminder identifier"),
                "title": .string(description: "Subtask title, for create"),
                "top_level": .boolean(description: "For move: make it a top-level reminder"),
            ],
            required: ["action"]
        )
    }

    static var listAppearance: Tool {
        make(
            name: "reminders_list_appearance",
            title: "List Icon or Emoji",
            description:
                "Set a list's icon to one of Reminders' own emblem names (for example education3; arbitrary SF Symbol names fall back to the default icon and are refused), or to an emoji. Pass icon or emoji, not both. Verified by reading the badge back.",
            properties: [
                "list": .string(description: "List name"),
                "list_id": .string(description: "List identifier"),
                "icon": .string(description: "Reminders emblem name such as education3"),
                "emoji": .string(description: "A single emoji such as 🎯"),
            ]
        )
    }

    static var groups: Tool {
        make(
            name: "reminders_groups",
            title: "Reminder List Groups",
            description:
                "Manage list groups, which are folders that hold lists, not reminders. Actions: list, create (name, optional add_lists of list names), rename (group or group_id, then name), delete (its lists move to the top level first), add_list and remove_list (group plus list or list_id).",
            properties: [
                "action": actions(["list", "create", "rename", "delete", "add_list", "remove_list"]),
                "name": .string(description: "Group name, for create; new name, for rename"),
                "group": .string(description: "Group name"),
                "group_id": .string(description: "Group identifier"),
                "add_lists": .array(description: "List names to put in a new group", items: .string()),
                "list": .string(description: "List name"),
                "list_id": .string(description: "List identifier"),
            ],
            required: ["action"],
            destructive: true
        )
    }

    static var smartLists: Tool {
        make(
            name: "reminders_smart_lists",
            title: "Custom Smart Lists",
            description:
                "Manage custom smart lists. Actions: list (with their filters), create (name, then tags for a list of reminders carrying any of those tags, or filter with a raw payload in Reminders' own smart-list format), and delete (smart_list or smart_list_id). Built-in smart lists are never changed. Needs an iCloud Reminders account. Created lists are read back, including the filter.",
            properties: [
                "action": actions(["list", "create", "delete"]),
                "name": .string(description: "Name of the new smart list"),
                "tags": .array(description: "Match reminders with any of these tags", items: .string()),
                "filter": .object(description: "Raw smart-list filter payload", properties: [:]),
                "smart_list": .string(description: "Smart list name"),
                "smart_list_id": .string(description: "Smart list identifier"),
            ],
            required: ["action"],
            destructive: true
        )
    }

    static var templates: Tool {
        make(
            name: "reminders_templates",
            title: "Reminder Templates",
            description:
                "Manage list templates. Actions: list, create (name, from a list or list_id, include_completed to keep finished reminders), apply (template or template_id; Reminders names the new list), and delete (the template only, never lists made from it). Needs an iCloud Reminders account.",
            properties: [
                "action": actions(["list", "create", "apply", "delete"]),
                "name": .string(description: "Template name, for create"),
                "list": .string(description: "Source list name, for create"),
                "list_id": .string(description: "Source list identifier, for create"),
                "include_completed": .boolean(description: "Keep completed reminders in the template"),
                "template": .string(description: "Template name"),
                "template_id": .string(description: "Template identifier"),
            ],
            required: ["action"],
            destructive: true
        )
    }

    static var restore: Tool {
        make(
            name: "reminders_restore",
            title: "Restore Deleted Reminder",
            description:
                "Restore a reminder from Recently Deleted by the identifier it had before deletion, into the list you name (ReminderKit no longer records the original list on a deleted reminder). Listing everything in Recently Deleted is not supported; keep the identifier from before the deletion.",
            properties: [
                "id": .string(description: idHelp),
                "list": .string(description: "List name to restore into"),
                "list_id": .string(description: "List identifier to restore into"),
            ],
            required: ["id"]
        )
    }
}

extension Value {
    /// A value decoded from plain JSON objects, arrays, strings, numbers, and booleans.
    init(jsonObject: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        self = try JSONDecoder().decode(Value.self, from: data)
    }
}
