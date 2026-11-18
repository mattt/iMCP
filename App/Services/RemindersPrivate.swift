import Foundation

/// The pure half of the private Reminders tools: the setting that gates them, argument
/// validation, request building, and response parsing. It has no ReminderKit calls.
/// Those live in `ReminderKitBridge.m`, which this file reaches by class name, so
/// everything here is unit tested without Apple's private framework.
///
/// Behavior follows the documented behavior of viticci/remctl (MIT). No remctl code is used.
enum RemindersPrivate {
    /// The setting that turns the private tools on. Off until the person chooses.
    ///
    /// This base has no per-service "Allow writes" mechanism (that is `feat/service-write-toggle`,
    /// PR #342), so the private tools carry their own switch. It covers their reads too,
    /// because every one of them goes through the unsupported ReminderKit API.
    static let settingKey = "remindersPrivateEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? false
    }

    static let disabledMessage =
        "Private Reminders features are off. Turn on \"Private Reminders features\" in iMCP Settings under Reminders. They use Apple's unsupported ReminderKit framework, which can change in any macOS update."

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

    private static func fail(_ code: String, _ message: String) -> RemindersInputError {
        RemindersInputError(code: code, message: message)
    }

    private static func reject(_ args: [String: Any], allowed: Set<String>) throws {
        if let unknown = args.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw fail("unknown_property", "Unknown property \"\(unknown)\".")
        }
    }

    private static func string(_ args: [String: Any], _ key: String, required: Bool = false) throws -> String? {
        guard let raw = args[key], !(raw is NSNull) else {
            if required { throw fail("missing_\(key)", "\(key) is required.") }
            return nil
        }
        guard let value = raw as? String else { throw fail("invalid_\(key)", "\(key) must be a string.") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if required { throw fail("missing_\(key)", "\(key) is required.") }
            throw fail("invalid_\(key)", "\(key) must not be empty.")
        }
        return trimmed
    }

    private static func bool(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw fail("invalid_\(key)", "\(key) must be true or false.")
        }
        return number.boolValue
    }

    /// An identifier as ReminderKit uses it: a UUID.
    static func identifier(_ args: [String: Any], _ key: String, required: Bool = true) throws -> String? {
        guard let value = try string(args, key, required: required) else { return nil }
        guard UUID(uuidString: value) != nil else {
            throw fail(
                "invalid_\(key)",
                "\(key) must be a reminder or list identifier (a UUID) as the other Reminders tools return it."
            )
        }
        return value
    }

    /// Pass a list by `list` (name) or `list_id`, never both and not neither.
    private static func listSelector(_ args: [String: Any]) throws -> [String: Any] {
        let name = try string(args, "list")
        let id = try identifier(args, "list_id", required: false)
        if name != nil && id != nil { throw fail("conflicting_list", "Pass list or list_id, not both.") }
        guard name != nil || id != nil else { throw fail("missing_list", "Pass list (a name) or list_id.") }
        var out: [String: Any] = [:]
        if let name { out["list"] = name }
        if let id { out["list_id"] = id }
        return out
    }

    private static func oneOf(_ args: [String: Any], _ key: String, _ allowed: [String]) throws -> String {
        guard let value = try string(args, key, required: true)?.lowercased(), allowed.contains(value) else {
            throw fail("invalid_\(key)", "\(key) must be one of: \(allowed.joined(separator: ", ")).")
        }
        return value
    }

    // MARK: - Tags

    static let maxTagLength = 64

    /// A tag as Reminders stores it: no leading `#`, no whitespace.
    static func cleanTag(_ raw: Any) throws -> String {
        guard let text = raw as? String else { throw fail("invalid_tags", "Each tag must be a string.") }
        var tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        guard !tag.isEmpty else { throw fail("invalid_tags", "A tag must not be empty.") }
        guard tag.count <= maxTagLength else {
            throw fail("invalid_tags", "A tag can be at most \(maxTagLength) characters.")
        }
        guard tag.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw fail("invalid_tags", "A tag cannot contain spaces: \"\(tag)\". Reminders tags are single words.")
        }
        return tag
    }

    private static func tagList(_ args: [String: Any], allowEmpty: Bool) throws -> [String] {
        guard let raw = args["tags"], !(raw is NSNull) else {
            throw fail("missing_tags", "tags is required for this action.")
        }
        guard let list = raw as? [Any] else { throw fail("invalid_tags", "tags must be an array of strings.") }
        if list.isEmpty && !allowEmpty { throw fail("invalid_tags", "tags must not be empty.") }
        guard list.count <= 50 else { throw fail("invalid_tags", "At most 50 tags per call.") }
        var seen = Set<String>()
        var out: [String] = []
        for item in list {
            let tag = try cleanTag(item)
            if seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return out
    }

    // MARK: - Request builders, one per tool

    /// Turns one tool call into a bridge request, or throws a clear input error.
    static func request(tool: String, arguments args: [String: Any]) throws -> Request {
        switch tool {
        case "reminders_tags": return try tags(args)
        case "reminders_add_link": return try addLink(args)
        case "reminders_flag": return try flag(args)
        case "reminders_get_private":
            try reject(args, allowed: ["id"])
            return Request(action: "reminder.info", args: ["id": try identifier(args, "id")!])
        case "reminders_sections": return try sections(args)
        case "reminders_subtasks": return try subtasks(args)
        case "reminders_list_appearance": return try appearance(args)
        case "reminders_groups": return try groups(args)
        case "reminders_smart_lists": return try smartLists(args)
        case "reminders_templates": return try templates(args)
        case "reminders_restore":
            try reject(args, allowed: ["id", "list", "list_id"])
            var out: [String: Any] = ["id": try identifier(args, "id")!]
            if args["list"] != nil || args["list_id"] != nil { out.merge(try listSelector(args)) { $1 } }
            return Request(action: "restore", args: out)
        default:
            throw fail("unknown_tool", "Unknown private Reminders tool \(tool).")
        }
    }

    private static func tags(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "tags", "list", "list_id"])
        let action = try oneOf(args, "action", ["list", "add", "set", "remove", "clear"])
        if action == "list" {
            return Request(action: "tags.list", args: try listSelector(args))
        }
        if args["list"] != nil || args["list_id"] != nil {
            throw fail("invalid_arguments", "list and list_id only apply to action list.")
        }
        var out: [String: Any] = ["mode": action, "id": try identifier(args, "id")!]
        switch action {
        case "clear":
            if args["tags"] != nil { throw fail("invalid_arguments", "clear takes no tags.") }
        case "set": out["tags"] = try tagList(args, allowEmpty: true)
        default: out["tags"] = try tagList(args, allowEmpty: false)
        }
        return Request(action: "tags", args: out)
    }

    /// Schemes Reminders cannot open as a rich link, plus file-server schemes.
    static let blockedLinkSchemes: Set<String> = [
        "file", "javascript", "data", "about", "blob", "smb", "afp", "nfs", "ftp", "ssh", "sftp", "vnc",
    ]

    /// Whether a host name or literal is one that must not become a rich link:
    /// loopback, `.local`, or a private or reserved address literal.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local")
            || h.hasSuffix(".internal") || h.hasSuffix(".lan")
        {
            return true
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0 ... 255).contains($0) }) {
            let (a, b) = (parts[0], parts[1])
            if a == 0 || a == 10 || a == 127 || a >= 224 { return true }
            if a == 169 && b == 254 { return true }
            if a == 172 && (16 ... 31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64 ... 127).contains(b) { return true }
            if a == 198 && (b == 18 || b == 19) { return true }
            return false
        }
        if h.contains(":") {
            // IPv6 literals: only a plain global unicast address is allowed.
            return h == "::1" || h == "::" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd")
                || h.hasPrefix("::ffff")
        }
        // A bare numeric host such as 2130706433 or 0x7f000001 is an address in disguise.
        if Int(h) != nil || h.hasPrefix("0x") { return true }
        return false
    }

    /// Validates a rich link: a public http or https address, or an app link with a safe scheme.
    /// Name resolution is not checked here, so a public-looking name that resolves to a private
    /// address is only caught by Reminders itself.
    static func validatedLink(_ text: String) throws -> String {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            throw fail("invalid_url", "url must be an absolute URL such as https://example.com.")
        }
        if blockedLinkSchemes.contains(scheme) {
            throw fail("invalid_url", "Reminders cannot show \(scheme): links.")
        }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { throw fail("invalid_url", "The URL has no host.") }
            if isPrivateHost(host) {
                throw fail(
                    "invalid_url",
                    "Web links must point at a public host. \(host) is local, private, or reserved."
                )
            }
        }
        guard URL(string: text) != nil else { throw fail("invalid_url", "url is not a valid URL.") }
        return text
    }

    private static func addLink(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["id", "url"])
        let url = try validatedLink(try string(args, "url", required: true)!)
        return Request(action: "link.add", args: ["id": try identifier(args, "id")!, "url": url])
    }

    private static func flag(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["id", "flagged", "urgent"])
        var out: [String: Any] = ["id": try identifier(args, "id")!]
        if let f = try bool(args, "flagged") { out["flagged"] = f }
        if let u = try bool(args, "urgent") { out["urgent"] = u }
        guard out["flagged"] != nil || out["urgent"] != nil else {
            throw fail("missing_change", "Pass flagged, urgent, or both.")
        }
        return Request(action: "flags", args: out)
    }

    private static func sections(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "list", "list_id", "section", "section_id", "name", "id"])
        let action = try oneOf(args, "action", ["list", "create", "rename", "delete", "assign"])
        var out: [String: Any] = ["mode": action]
        func sectionSelector() throws {
            let name = try string(args, "section")
            let id = try identifier(args, "section_id", required: false)
            if name != nil && id != nil { throw fail("conflicting_section", "Pass section or section_id, not both.") }
            guard name != nil || id != nil else {
                throw fail("missing_section", "Pass section (a name) or section_id.")
            }
            if let name { out["section"] = name }
            if let id { out["section_id"] = id }
        }
        switch action {
        case "list":
            out.merge(try listSelector(args)) { $1 }
        case "create":
            out.merge(try listSelector(args)) { $1 }
            out["name"] = try string(args, "name", required: true)!
        case "rename":
            out.merge(try listSelector(args)) { $1 }
            try sectionSelector()
            out["name"] = try string(args, "name", required: true)!
        case "delete":
            out.merge(try listSelector(args)) { $1 }
            try sectionSelector()
        default:  // assign
            out["id"] = try identifier(args, "id")!
            try sectionSelector()
        }
        return Request(action: "sections", args: out)
    }

    private static func subtasks(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "id", "parent_id", "title", "top_level"])
        let action = try oneOf(args, "action", ["create", "list", "move"])
        switch action {
        case "create":
            return Request(
                action: "subtasks",
                args: [
                    "mode": "create", "parent_id": try identifier(args, "parent_id")!,
                    "title": try string(args, "title", required: true)!,
                ]
            )
        case "list":
            return Request(action: "subtasks", args: ["mode": "list", "parent_id": try identifier(args, "parent_id")!])
        default:
            let top = try bool(args, "top_level") ?? false
            let parent = try identifier(args, "parent_id", required: false)
            if top == (parent != nil) {
                throw fail(
                    "invalid_arguments",
                    "Pass parent_id to nest the reminder, or top_level true to make it a top-level reminder."
                )
            }
            var out: [String: Any] = ["mode": "move", "id": try identifier(args, "id")!, "top_level": top]
            if let parent { out["parent_id"] = parent }
            return Request(action: "subtasks", args: out)
        }
    }

    /// An emblem name as Reminders' own picker writes it, such as `education3`.
    static func isEmblemName(_ text: String) -> Bool {
        guard text.count <= 40, let first = text.unicodeScalars.first, first.properties.isLowercase else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            ($0.value < 128) && ($0.properties.isLowercase || ("0" ... "9").contains($0) || $0 == "_")
        }
    }

    /// One emoji: a single character whose first scalar is an emoji presentation or emoji symbol.
    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && first.value > 0x238C)
            || text.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    private static func appearance(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["list", "list_id", "icon", "emoji"])
        var out = try listSelector(args)
        let icon = try string(args, "icon")
        let emoji = try string(args, "emoji")
        guard (icon == nil) != (emoji == nil) else {
            throw fail("invalid_arguments", "Pass exactly one of icon or emoji.")
        }
        if let icon {
            guard isEmblemName(icon) else {
                throw fail(
                    "invalid_icon",
                    "icon must be one of Reminders' own emblem names, lowercase letters and digits such as education3. SF Symbol names do not work."
                )
            }
            out["icon"] = icon
        }
        if let emoji {
            guard isSingleEmoji(emoji) else { throw fail("invalid_emoji", "emoji must be a single emoji character.") }
            out["emoji"] = emoji
        }
        return Request(action: "appearance", args: out)
    }

    private static func groups(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "group", "group_id", "name", "add_lists", "list", "list_id"])
        let action = try oneOf(args, "action", ["list", "create", "rename", "delete", "add_list", "remove_list"])
        var out: [String: Any] = ["mode": action]
        func groupSelector() throws {
            let name = try string(args, "group")
            let id = try identifier(args, "group_id", required: false)
            if name != nil && id != nil { throw fail("conflicting_group", "Pass group or group_id, not both.") }
            guard name != nil || id != nil else { throw fail("missing_group", "Pass group (a name) or group_id.") }
            if let name { out["group"] = name }
            if let id { out["group_id"] = id }
        }
        switch action {
        case "list": break
        case "create":
            out["name"] = try string(args, "name", required: true)!
            if let raw = args["add_lists"], !(raw is NSNull) {
                guard let names = raw as? [String], !names.isEmpty, names.count <= 50,
                    names.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                else {
                    throw fail("invalid_add_lists", "add_lists must be a non-empty array of list names.")
                }
                out["add_lists"] = names
            }
        case "rename":
            try groupSelector()
            out["name"] = try string(args, "name", required: true)!
        case "delete":
            try groupSelector()
        default:  // add_list, remove_list
            try groupSelector()
            out.merge(try listSelector(args)) { $1 }
        }
        return Request(action: "groups", args: out)
    }

    /// The filter payload Reminders stores for a custom smart list.
    static func tagFilter(_ tags: [String]) -> [String: Any] {
        ["hashtags": ["hashtags": ["operation": "or", "include": tags, "exclude": [String]()]]]
    }

    private static func smartLists(_ args: [String: Any]) throws -> Request {
        try reject(args, allowed: ["action", "name", "tags", "filter", "smart_list", "smart_list_id"])
        let action = try oneOf(args, "action", ["list", "create", "delete"])
        var out: [String: Any] = ["mode": action]
        switch action {
        case "list": break
        case "create":
            out["name"] = try string(args, "name", required: true)!
            let hasFilter = args["filter"] != nil && !(args["filter"] is NSNull)
            let hasTags = args["tags"] != nil && !(args["tags"] is NSNull)
            guard hasFilter != hasTags else { throw fail("invalid_arguments", "Pass exactly one of tags or filter.") }
            if hasTags {
                out["filter"] = tagFilter(try tagList(args, allowEmpty: false))
            } else {
                guard let filter = args["filter"] as? [String: Any], !filter.isEmpty else {
                    throw fail(
                        "invalid_filter",
                        "filter must be a non-empty JSON object in Reminders' smart-list filter format."
                    )
                }
                out["filter"] = filter
            }
        default:
            let name = try string(args, "smart_list")
            let id = try identifier(args, "smart_list_id", required: false)
            if name != nil && id != nil {
                throw fail("conflicting_smart_list", "Pass smart_list or smart_list_id, not both.")
            }
            guard name != nil || id != nil else {
                throw fail("missing_smart_list", "Pass smart_list (a name) or smart_list_id.")
            }
            if let name { out["smart_list"] = name }
            if let id { out["smart_list_id"] = id }
        }
        return Request(action: "smart_lists", args: out)
    }

    private static func templates(_ args: [String: Any]) throws -> Request {
        try reject(
            args,
            allowed: ["action", "name", "list", "list_id", "include_completed", "template", "template_id"]
        )
        let action = try oneOf(args, "action", ["list", "create", "apply", "delete"])
        var out: [String: Any] = ["mode": action]
        switch action {
        case "list": break
        case "create":
            out["name"] = try string(args, "name", required: true)!
            out.merge(try listSelector(args)) { $1 }
            out["include_completed"] = try bool(args, "include_completed") ?? false
        default:
            let name = try string(args, "template")
            let id = try identifier(args, "template_id", required: false)
            if name != nil && id != nil {
                throw fail("conflicting_template", "Pass template or template_id, not both.")
            }
            guard name != nil || id != nil else {
                throw fail("missing_template", "Pass template (a name) or template_id.")
            }
            if let name { out["template"] = name }
            if let id { out["template_id"] = id }
        }
        return Request(action: "templates", args: out)
    }

    // MARK: - Responses

    /// Reads the bridge's JSON reply: the result object, or a thrown error that carries ReminderKit's code.
    static func parse(response text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = object["ok"] as? Bool
        else {
            throw fail("bridge_failed", "The ReminderKit bridge returned something unreadable.")
        }
        if ok { return object["result"] as? [String: Any] ?? [:] }
        let error = object["error"] as? [String: Any]
        throw fail(
            error?["code"] as? String ?? "bridge_failed",
            error?["message"] as? String ?? "The ReminderKit bridge failed."
        )
    }

    /// Whether a write read back as intended. A result without `verified` counts as unverified.
    static func isVerified(_ result: [String: Any]) -> Bool {
        (result["verified"] as? Bool) == true
    }

    /// The result as clients see it: the bridge's fields, `verified` always present, and a
    /// warning when the readback did not confirm the change.
    static func shape(_ result: [String: Any], isWrite: Bool) -> [String: Any] {
        var out = result
        guard isWrite else { return out }
        let verified = isVerified(result)
        out["verified"] = verified
        if !verified {
            out["warning"] =
                "Reminders accepted the change, but reading it back did not confirm it. Check the reminder in Reminders before relying on it."
        }
        return out
    }

    /// Which tool calls write. `list` and `get` style calls only read.
    static func isWrite(tool: String, arguments args: [String: Any]) -> Bool {
        switch tool {
        case "reminders_get_private": return false
        case "reminders_tags", "reminders_sections", "reminders_subtasks", "reminders_groups", "reminders_smart_lists",
            "reminders_templates":
            return (args["action"] as? String)?.lowercased() != "list"
        default: return true
        }
    }

    // MARK: - Calling the bridge

    private static let queue = DispatchQueue(label: "com.amesconsulting.imcp.reminderkit", qos: .userInitiated)

    /// Runs one request on a private serial queue and returns the parsed result.
    static func perform(_ request: Request) async throws -> [String: Any] {
        guard let bridge = NSClassFromString("IMCPReminderKitBridge") as AnyObject? else {
            throw fail("bridge_missing", "This build of iMCP does not include the ReminderKit bridge.")
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

    /// Validates a tool call, runs it, and shapes the result. The setting is checked first.
    static func run(
        tool: String,
        arguments: [String: Any],
        defaults: UserDefaults = .standard
    ) async throws -> [String: Any] {
        guard isEnabled(defaults: defaults) else { throw fail("private_disabled", disabledMessage) }
        let request = try request(tool: tool, arguments: arguments)
        let result = try await perform(request)
        return shape(result, isWrite: isWrite(tool: tool, arguments: arguments))
    }
}
