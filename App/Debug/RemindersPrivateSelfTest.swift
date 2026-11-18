#if DEBUG
    import Foundation

    /// DEBUG-only live check of the private Reminders tools against real ReminderKit.
    /// Run with the launch argument `--reminders-private-selftest`. It makes a throwaway list
    /// named "iMCP test <timestamp>" (plus a group, smart list, template, and the list a template
    /// creates, all named from it), exercises every private tool on it through the same code the
    /// tools use, prints each step as JSON, deletes everything it made, and exits.
    /// It never touches a reminder, list, or group it did not create.
    enum RemindersPrivateSelfTest {
        private struct Step {
            var name: String
            var ok: Bool
            var verified: Bool?
            var detail: String
        }

        static func run() async -> String {
            let suite = UserDefaults(suiteName: "RemindersPrivateSelfTest")!
            suite.set(true, forKey: RemindersPrivate.settingKey)

            let stamp: String = {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd-HHmmss"
                return f.string(from: Date())
            }()
            let listName = "iMCP test \(stamp)"
            var steps: [[String: Any]] = []

            func record(_ name: String, _ result: Result<[String: Any], Error>) {
                switch result {
                case .success(let r):
                    var entry: [String: Any] = ["step": name, "ok": true]
                    if let v = r["verified"] as? Bool { entry["verified"] = v }
                    entry["detail"] = r
                    steps.append(entry)
                case .failure(let e):
                    steps.append(["step": name, "ok": false, "detail": "\(e)"])
                }
            }

            @discardableResult
            func call(_ name: String, tool: String, _ args: [String: Any]) async -> [String: Any]? {
                do {
                    let r = try await RemindersPrivate.run(tool: tool, arguments: args, defaults: suite)
                    record(name, .success(r))
                    return r
                } catch {
                    record(name, .failure(error))
                    return nil
                }
            }

            @discardableResult
            func raw(_ name: String, _ action: String, _ args: [String: Any], quiet: Bool = false) async -> [String:
                Any]?
            {
                do {
                    let r = try await RemindersPrivate.perform(.init(action: action, args: args))
                    if !quiet { record(name, .success(r)) }
                    return r
                } catch {
                    record(name, .failure(error))
                    return nil
                }
            }

            _ = await raw("status", "status", [:])
            _ = await raw("accounts", "debug.accounts", [:])
            guard let list = await raw("create throwaway list", "debug.create_list", ["name": listName]),
                let listID = list["id"] as? String
            else { return output(steps, listName) }
            var extraLists: [String] = []

            let a = await raw("create reminder A", "debug.create_reminder", ["list_id": listID, "title": "A \(stamp)"])
            let b = await raw("create reminder B", "debug.create_reminder", ["list_id": listID, "title": "B \(stamp)"])
            if let aID = a?["id"] as? String, let bID = b?["id"] as? String {
                await raw("EventKit sees the ReminderKit id", "debug.eventkit_has_reminder", ["id": aID])
                await call("get private (fresh)", tool: "reminders_get_private", ["id": aID])

                await call(
                    "tags add",
                    tool: "reminders_tags",
                    ["action": "add", "id": aID, "tags": ["alpha", "#beta"]]
                )
                await call(
                    "tags set",
                    tool: "reminders_tags",
                    ["action": "set", "id": aID, "tags": ["gamma", "alpha"]]
                )
                await call("tags remove", tool: "reminders_tags", ["action": "remove", "id": aID, "tags": ["alpha"]])
                await call("tags list in list", tool: "reminders_tags", ["action": "list", "list_id": listID])
                await call("tags clear", tool: "reminders_tags", ["action": "clear", "id": aID])

                await call("add link", tool: "reminders_add_link", ["id": aID, "url": "https://example.com/"])
                await call("flag", tool: "reminders_flag", ["id": aID, "flagged": true])
                await call("urgent", tool: "reminders_flag", ["id": aID, "urgent": true])
                await call(
                    "unflag and not urgent",
                    tool: "reminders_flag",
                    ["id": aID, "flagged": false, "urgent": false]
                )

                await call(
                    "section create",
                    tool: "reminders_sections",
                    ["action": "create", "list_id": listID, "name": "S1"]
                )
                await call("section list", tool: "reminders_sections", ["action": "list", "list_id": listID])
                await call(
                    "section rename",
                    tool: "reminders_sections",
                    ["action": "rename", "list_id": listID, "section": "S1", "name": "S2"]
                )
                await call(
                    "section assign",
                    tool: "reminders_sections",
                    ["action": "assign", "id": aID, "section": "S2", "list_id": listID]
                )
                await call("get private (section)", tool: "reminders_get_private", ["id": aID])
                await call(
                    "section delete",
                    tool: "reminders_sections",
                    ["action": "delete", "list_id": listID, "section": "S2"]
                )
                await call("get private (after section delete)", tool: "reminders_get_private", ["id": aID])

                let sub = await call(
                    "subtask create",
                    tool: "reminders_subtasks",
                    ["action": "create", "parent_id": aID, "title": "child \(stamp)"]
                )
                await call(
                    "subtask move B under A",
                    tool: "reminders_subtasks",
                    ["action": "move", "id": bID, "parent_id": aID]
                )
                await call("subtask list", tool: "reminders_subtasks", ["action": "list", "parent_id": aID])
                await call(
                    "subtask B to top level",
                    tool: "reminders_subtasks",
                    ["action": "move", "id": bID, "top_level": true]
                )
                _ = sub

                await call("list icon", tool: "reminders_list_appearance", ["list_id": listID, "icon": "education3"])
                await call("list emoji", tool: "reminders_list_appearance", ["list_id": listID, "emoji": "🎯"])

                let groupName = "iMCP test group \(stamp)"
                await call(
                    "group create with list",
                    tool: "reminders_groups",
                    ["action": "create", "name": groupName, "add_lists": [listName]]
                )
                await call("group list", tool: "reminders_groups", ["action": "list"])
                await call(
                    "group rename",
                    tool: "reminders_groups",
                    ["action": "rename", "group": groupName, "name": groupName + " 2"]
                )
                await call(
                    "group remove list",
                    tool: "reminders_groups",
                    ["action": "remove_list", "group": groupName + " 2", "list_id": listID]
                )
                await call(
                    "group add list",
                    tool: "reminders_groups",
                    ["action": "add_list", "group": groupName + " 2", "list_id": listID]
                )
                await call("group delete", tool: "reminders_groups", ["action": "delete", "group": groupName + " 2"])

                let smartName = "iMCP test smart \(stamp)"
                await call(
                    "smart list create",
                    tool: "reminders_smart_lists",
                    ["action": "create", "name": smartName, "tags": ["imcptest"]]
                )
                await call("smart list list", tool: "reminders_smart_lists", ["action": "list"])
                await call(
                    "smart list delete",
                    tool: "reminders_smart_lists",
                    ["action": "delete", "smart_list": smartName]
                )

                let templateName = "iMCP test template \(stamp)"
                await call(
                    "template create",
                    tool: "reminders_templates",
                    ["action": "create", "name": templateName, "list_id": listID]
                )
                await call("template list", tool: "reminders_templates", ["action": "list"])
                if let applied = await call(
                    "template apply",
                    tool: "reminders_templates",
                    ["action": "apply", "template": templateName]
                ),
                    let created = applied["createdLists"] as? [[String: Any]]
                {
                    extraLists += created.compactMap { $0["id"] as? String }
                }
                await call(
                    "template delete",
                    tool: "reminders_templates",
                    ["action": "delete", "template": templateName]
                )

                await raw("delete reminder B", "debug.delete_reminder", ["id": bID])
                await raw("describe deleted B", "debug.describe_deleted", ["id": bID])
                await call("restore reminder B", tool: "reminders_restore", ["id": bID, "list_id": listID])
            }

            // Cleanup: only objects created above.
            for id in extraLists { await raw("cleanup applied-template list", "debug.delete_list", ["list_id": id]) }
            await raw("cleanup throwaway list", "debug.delete_list", ["list_id": listID])
            if let left = await raw("leftovers", "debug.leftovers", [:], quiet: true) {
                let items = (left["leftovers"] as? [[String: Any]]) ?? []
                steps.append([
                    "step": "no leftover lists, groups, smart lists, or templates named iMCP test", "ok": items.isEmpty,
                    "detail": items,
                ])
            }
            return output(steps, listName)
        }

        private static func output(_ steps: [[String: Any]], _ listName: String) -> String {
            let report: [String: Any] = [
                "bundleID": Bundle.main.bundleIdentifier ?? "?",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "listName": listName,
                "steps": steps,
            ]
            let data =
                (try? JSONSerialization.data(
                    withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
#endif
