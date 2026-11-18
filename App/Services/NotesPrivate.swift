import Foundation

/// The pure half of the private Notes tools: the settings that gate them, argument validation,
/// request building, and response parsing. It makes no NotesShared calls.
/// Those live in `NotesSharedBridge.m`, which this file reaches by class name, so everything
/// here is unit tested without Apple's private framework.
///
/// Behavior follows the documented behavior of sweetrb/apple-notes-mcp's native features
/// (native tags, checklists, tables, pinning, note links, rich append, Markdown creation).
/// No code from that project is used.
enum NotesPrivate {
    /// The setting that turns the private tools on. Off until the person chooses.
    ///
    /// It covers their reads too, because every one of them goes through the unsupported
    /// NotesShared framework. Changes also need "Allow iMCP to change notes and folders".
    static let settingKey = "notesPrivateEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? false
    }

    static let disabledMessage =
        "Private Notes features are off. Turn on \"Private Notes features\" in iMCP Settings under Notes. They use Apple's unsupported NotesShared framework, which can change in any macOS update."

    static let writesDisabledMessage =
        "Changing notes is turned off. Turn on \"Allow iMCP to change notes and folders\" in iMCP's Notes settings to use this."

    /// An input or bridge error with a stable code.
    struct Failure: LocalizedError, CustomStringConvertible, Equatable {
        let code: String
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// One call into the bridge.
    struct Request {
        let action: String
        let args: [String: Any]

        var json: String {
            let object: [String: Any] = ["action": action, "args": args]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Argument helpers

    private static func fail(_ code: String, _ message: String) -> Failure {
        Failure(code: code, message: message)
    }

    private static func reject(_ args: [String: Any], allowed: Set<String>) throws {
        if let unknown = args.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw fail("unknown_property", "Unknown property \"\(unknown)\".")
        }
    }

    private static func string(
        _ args: [String: Any],
        _ key: String,
        required: Bool = false,
        limit: Int = 500,
        trim: Bool = true
    ) throws -> String? {
        guard let raw = args[key], !(raw is NSNull) else {
            if required { throw fail("missing_\(key)", "\(key) is required.") }
            return nil
        }
        guard let value = raw as? String else { throw fail("invalid_\(key)", "\(key) must be a string.") }
        let text = trim ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if required { throw fail("missing_\(key)", "\(key) is required.") }
            throw fail("invalid_\(key)", "\(key) must not be empty.")
        }
        guard text.count <= limit else { throw fail("invalid_\(key)", "\(key) can be at most \(limit) characters.") }
        return text
    }

    private static func bool(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw fail("invalid_\(key)", "\(key) must be true or false.")
        }
        return number.boolValue
    }

    private static func oneOf(_ args: [String: Any], _ key: String, _ allowed: [String]) throws -> String {
        guard let value = try string(args, key, required: true)?.lowercased(), allowed.contains(value) else {
            throw fail("invalid_\(key)", "\(key) must be one of: \(allowed.joined(separator: ", ")).")
        }
        return value
    }

    /// A note id as the other Notes tools return it (`x-coredata://…/ICNote/pN`), the note's UUID,
    /// or a notes:// link that carries the UUID.
    static func noteIdentifier(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("x-coredata://"), text.contains("/ICNote/") { return text }
        if UUID(uuidString: text) != nil { return text }
        if let components = URLComponents(string: text), ["notes", "applenotes"].contains(components.scheme ?? ""),
            let value = components.queryItems?.first(where: { $0.name == "identifier" })?.value,
            UUID(uuidString: value) != nil
        {
            return value
        }
        throw fail(
            "invalid_id",
            "id must be a note id from notes_get, notes_list_recent, or notes_create (x-coredata://…/ICNote/pN), a note UUID, or a notes:// link."
        )
    }

    private static func noteID(_ args: [String: Any], _ key: String = "id") throws -> String {
        try noteIdentifier(try string(args, key, required: true, limit: 600)!)
    }

    // MARK: - Tags

    static let maxTagLength = 64

    /// A tag as Notes stores it: no leading `#`, no whitespace.
    static func cleanTag(_ raw: Any) throws -> String {
        guard let text = raw as? String else { throw fail("invalid_tags", "Each tag must be a string.") }
        var tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        guard !tag.isEmpty else { throw fail("invalid_tags", "A tag must not be empty.") }
        guard tag.count <= maxTagLength else {
            throw fail("invalid_tags", "A tag can be at most \(maxTagLength) characters.")
        }
        guard tag.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw fail("invalid_tags", "A tag cannot contain spaces: \"\(tag)\". Notes tags are single words.")
        }
        return tag
    }

    private static func tagList(_ args: [String: Any]) throws -> [String] {
        guard let raw = args["tags"], !(raw is NSNull) else {
            throw fail("missing_tags", "tags is required for this action.")
        }
        guard let list = raw as? [Any], !list.isEmpty else {
            throw fail("invalid_tags", "tags must be a non-empty array of strings.")
        }
        guard list.count <= 100 else { throw fail("invalid_tags", "At most 100 tags per call.") }
        var seen = Set<String>()
        var out: [String] = []
        for item in list {
            let tag = try cleanTag(item)
            if seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return out
    }

    // MARK: - Checklists and tables

    static let maxChecklistItems = 20
    static let maxChecklistItemLength = 1000

    static func checklistItems(_ args: [String: Any]) throws -> [String] {
        guard let raw = args["items"] as? [Any], !raw.isEmpty else {
            throw fail("invalid_items", "items must be a non-empty array of strings.")
        }
        guard raw.count <= maxChecklistItems else {
            throw fail("invalid_items", "At most \(maxChecklistItems) checklist items per call.")
        }
        return try raw.map { item in
            guard let text = (item as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                throw fail("invalid_items", "Each checklist item must be a non-empty string.")
            }
            guard !text.contains("\n"), !text.contains("\r"), !text.contains("\u{FFFC}") else {
                throw fail("invalid_items", "A checklist item must be one line. Pass one item per entry.")
            }
            guard text.count <= maxChecklistItemLength else {
                throw fail("invalid_items", "A checklist item can be at most \(maxChecklistItemLength) characters.")
            }
            return text
        }
    }

    static let maxTableRows = 1000
    static let maxTableColumns = 100
    static let maxCellLength = 2000

    static func tableRows(_ args: [String: Any]) throws -> [[String]] {
        guard let raw = args["rows"] as? [Any], !raw.isEmpty else {
            throw fail("invalid_rows", "rows must be a non-empty array of rows, each an array of strings.")
        }
        guard raw.count <= maxTableRows else { throw fail("invalid_rows", "At most \(maxTableRows) rows.") }
        var rows: [[String]] = []
        for row in raw {
            guard let cells = row as? [Any], !cells.isEmpty else {
                throw fail("invalid_rows", "Each row must be a non-empty array of strings.")
            }
            guard cells.count <= maxTableColumns else {
                throw fail("invalid_rows", "At most \(maxTableColumns) columns.")
            }
            rows.append(
                try cells.map { cell in
                    guard let text = cell as? String else { throw fail("invalid_rows", "Every cell must be a string.") }
                    guard !text.contains("\t"), !text.contains("\n"), !text.contains("\r"), !text.contains("\u{FFFC}")
                    else {
                        throw fail(
                            "invalid_rows",
                            "A cell cannot contain a tab or a line break. Notes tables take one line per cell."
                        )
                    }
                    guard text.count <= maxCellLength else {
                        throw fail("invalid_rows", "A cell can be at most \(maxCellLength) characters.")
                    }
                    return text
                }
            )
        }
        let width = rows[0].count
        guard rows.allSatisfy({ $0.count == width }) else {
            throw fail("invalid_rows", "Every row must have the same number of cells.")
        }
        return rows
    }

    static let maxContentLength = 200_000

    // MARK: - Request builders, one per tool

    /// Turns one tool call into a bridge request, or throws a clear input error.
    static func request(tool: String, arguments args: [String: Any]) throws -> Request {
        switch tool {
        case "notes_structure":
            try reject(args, allowed: ["id", "blocks"])
            return Request(
                action: "structure",
                args: ["id": try noteID(args), "blocks": try bool(args, "blocks") ?? false]
            )
        case "notes_tags": return try tags(args)
        case "notes_pin":
            try reject(args, allowed: ["id", "pinned", "expected_pinned"])
            guard let pinned = try bool(args, "pinned") else { throw fail("missing_pinned", "pinned is required.") }
            var out: [String: Any] = ["id": try noteID(args), "pinned": pinned]
            if let expected = try bool(args, "expected_pinned") { out["expectedPinned"] = expected }
            return Request(action: "pin", args: out)
        case "notes_checklist": return try checklist(args)
        case "notes_table": return try table(args)
        case "notes_link": return try link(args)
        case "notes_append_rich":
            try reject(args, allowed: ["id", "content", "format"])
            let format = try args["format"] == nil ? "plaintext" : oneOf(args, "format", ["plaintext", "markdown"])
            return Request(
                action: "append",
                args: [
                    "id": try noteID(args),
                    "content": try string(args, "content", required: true, limit: maxContentLength, trim: false)!,
                    "format": format,
                ]
            )
        case "notes_create_markdown":
            try reject(args, allowed: ["markdown", "title", "folder", "account"])
            var markdown = try string(args, "markdown", required: true, limit: maxContentLength, trim: false)!
            if let title = try string(args, "title", limit: 250) {
                guard !title.contains("\n") else { throw fail("invalid_title", "title must be one line.") }
                markdown = createMarkdownBody(title: title, markdown: markdown)
            }
            var out: [String: Any] = ["markdown": markdown]
            if let folder = try string(args, "folder", limit: 2000) { out["folder"] = folder }
            if let account = try string(args, "account", limit: 200) { out["account"] = account }
            return Request(action: "create_markdown", args: out)
        default:
            throw fail("unknown_tool", "Unknown private Notes tool \(tool).")
        }
    }

    /// Puts `title` first as a heading, unless the Markdown already opens with a heading.
    static func createMarkdownBody(title: String, markdown: String) -> String {
        let first = markdown.drop(while: { $0.isNewline || $0 == " " })
        if first.hasPrefix("#") { return markdown }
        return "# \(title)\n\n\(markdown)"
    }

    private static func tags(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "ids", "folder", "account", "tags", "old", "new"])
        let action = try oneOf(args, "action", ["list", "add", "remove", "replace"])
        switch action {
        case "list":
            if args["tags"] != nil || args["old"] != nil || args["new"] != nil || args["ids"] != nil {
                throw fail("invalid_arguments", "list takes id, folder, or neither (the account-wide inventory).")
            }
            if args["id"] != nil && args["folder"] != nil {
                throw fail("conflicting_scope", "Pass id or folder, not both.")
            }
            var out: [String: Any] = [:]
            if args["id"] != nil { out["id"] = try noteID(args) }
            if let folder = try string(args, "folder", limit: 2000) { out["folder"] = folder }
            if let account = try string(args, "account", limit: 200) {
                guard out["folder"] != nil else {
                    throw fail("invalid_arguments", "account only applies with folder.")
                }
                out["account"] = account
            }
            return Request(action: "tags.list", args: out)
        case "add", "remove":
            if args["ids"] != nil || args["old"] != nil || args["new"] != nil || args["folder"] != nil {
                throw fail("invalid_arguments", "\(action) takes id and tags.")
            }
            return Request(action: "tags.change", args: ["mode": action, "id": try noteID(args), "tags": try tagList(args)])
        default:
            if args["tags"] != nil || args["folder"] != nil {
                throw fail("invalid_arguments", "replace takes ids (or id), old, and new.")
            }
            var ids: [String] = []
            if let raw = args["ids"] {
                guard let list = raw as? [Any], !list.isEmpty, list.count <= 100 else {
                    throw fail("invalid_ids", "ids must be an array of 1 to 100 note ids.")
                }
                ids = try list.map {
                    guard let s = $0 as? String else { throw fail("invalid_ids", "Each id must be a string.") }
                    return try noteIdentifier(s)
                }
            }
            if args["id"] != nil { ids.append(try noteID(args)) }
            guard !ids.isEmpty else { throw fail("missing_id", "Pass ids (or id) for the notes to change.") }
            guard let old = args["old"], let new = args["new"] else {
                throw fail("missing_tags", "replace needs old and new.")
            }
            return Request(
                action: "tags.change",
                args: ["mode": "replace", "ids": ids, "old": try cleanTag(old), "new": try cleanTag(new)]
            )
        }
    }

    private static func checklist(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "items", "done", "index", "text"])
        let action = try oneOf(args, "action", ["get", "add", "set"])
        let id = try noteID(args)
        switch action {
        case "get":
            if args.count > 2 { throw fail("invalid_arguments", "get takes only id.") }
            return Request(action: "checklist.get", args: ["id": id])
        case "add":
            if args["index"] != nil || args["text"] != nil {
                throw fail("invalid_arguments", "add takes id, items, and optionally done.")
            }
            return Request(
                action: "checklist.add",
                args: ["id": id, "items": try checklistItems(args), "done": try bool(args, "done") ?? false]
            )
        default:
            if args["items"] != nil { throw fail("invalid_arguments", "set takes id, done, and index or text.") }
            guard let done = try bool(args, "done") else { throw fail("missing_done", "done is required for set.") }
            var out: [String: Any] = ["id": id, "done": done]
            let text = try string(args, "text", limit: maxChecklistItemLength)
            if let raw = args["index"], !(raw is NSNull) {
                guard text == nil else { throw fail("conflicting_item", "Pass index or text, not both.") }
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let n = Int(exactly: number), n >= 0, n < 10_000 else {
                    throw fail("invalid_index", "index must be a whole number, counted from 0.")
                }
                out["index"] = n
            } else if let text {
                out["text"] = text
            } else {
                throw fail("missing_item", "Pass index (from 0) or text to say which item.")
            }
            return Request(action: "checklist.set", args: out)
        }
    }

    private static func table(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "rows"])
        let action = try oneOf(args, "action", ["get", "create"])
        let id = try noteID(args)
        if action == "get" {
            if args["rows"] != nil { throw fail("invalid_arguments", "get takes only id.") }
            return Request(action: "table.get", args: ["id": id])
        }
        return Request(action: "table.create", args: ["id": id, "rows": try tableRows(args)])
    }

    private static func link(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "target", "label"])
        let action = try oneOf(args, "action", ["get", "list", "insert"])
        let id = try noteID(args)
        switch action {
        case "get", "list":
            if args["target"] != nil || args["label"] != nil {
                throw fail("invalid_arguments", "\(action) takes only id.")
            }
            return Request(action: action == "get" ? "link.get" : "link.list", args: ["id": id])
        default:
            var out: [String: Any] = ["id": id, "target": try noteID(args, "target")]
            if let label = try string(args, "label", limit: 200) {
                guard !label.contains("\n") else { throw fail("invalid_label", "label must be one line.") }
                out["label"] = label
            }
            return Request(action: "link.insert", args: out)
        }
    }

    // MARK: - Responses

    /// Reads the bridge's JSON reply: the result object, or a thrown error that carries its code.
    static func parse(response text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = object["ok"] as? Bool
        else {
            throw fail("bridge_failed", "The NotesShared bridge returned something unreadable.")
        }
        if ok { return object["result"] as? [String: Any] ?? [:] }
        let error = object["error"] as? [String: Any]
        throw fail(
            error?["code"] as? String ?? "bridge_failed",
            error?["message"] as? String ?? "The NotesShared bridge failed."
        )
    }

    /// Whether a write read back as intended. A result without `verified` counts as unverified.
    static func isVerified(_ result: [String: Any]) -> Bool {
        (result["verified"] as? Bool) == true
    }

    /// The result as clients see it: the bridge's fields, `verified` always present on writes,
    /// and a warning when the readback did not confirm the change.
    static func shape(_ result: [String: Any], isWrite: Bool) -> [String: Any] {
        var out = result
        guard isWrite else { return out }
        let verified = isVerified(result)
        out["verified"] = verified
        if !verified {
            out["warning"] =
                "Notes accepted the change, but reading it back did not confirm it. Check the note in Notes before relying on it."
        }
        return out
    }

    /// Which tool calls change something. Reads (`get`, `list`, structure) do not.
    static func isWrite(tool: String, arguments args: [String: Any]) -> Bool {
        switch tool {
        case "notes_structure": return false
        case "notes_tags": return (args["action"] as? String)?.lowercased() != "list"
        case "notes_checklist": return (args["action"] as? String)?.lowercased() == "add" || (args["action"] as? String)?.lowercased() == "set"
        case "notes_table": return (args["action"] as? String)?.lowercased() == "create"
        case "notes_link": return (args["action"] as? String)?.lowercased() == "insert"
        default: return true
        }
    }

    // MARK: - Calling the bridge

    private static let queue = DispatchQueue(label: "com.amesconsulting.imcp.notesshared", qos: .userInitiated)

    /// Runs one request on a private serial queue and returns the parsed result.
    static func perform(_ request: Request) async throws -> [String: Any] {
        guard let bridge = NSClassFromString("IMCPNotesSharedBridge") as AnyObject? else {
            throw fail("bridge_missing", "This build of iMCP does not include the NotesShared bridge.")
        }
        let json = request.json
        let reply: String = await withCheckedContinuation { continuation in
            queue.async {
                let unmanaged = bridge.perform(Selector(("perform:")), with: json)
                continuation.resume(returning: unmanaged?.takeUnretainedValue() as? String ?? "")
            }
        }
        return try parse(response: reply)
    }

    /// Validates a tool call, runs it, and shapes the result. The settings are checked first.
    static func run(
        tool: String,
        arguments: [String: Any],
        defaults: UserDefaults = .standard
    ) async throws -> [String: Any] {
        guard isEnabled(defaults: defaults) else { throw fail("private_disabled", disabledMessage) }
        let request = try request(tool: tool, arguments: arguments)
        let write = isWrite(tool: tool, arguments: arguments)
        if write, !NotesWriteTools.writesEnabled(in: defaults) {
            throw fail("writes_disabled", writesDisabledMessage)
        }
        let result = try await perform(request)
        return shape(result, isWrite: write)
    }
}
