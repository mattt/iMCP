import Foundation
import XCTest

final class RemindersPrivateTests: XCTestCase {
    private let id1 = "9BBB98FB-F474-42DA-AAF4-B218529853CB"
    private let id2 = "26B00663-4A16-4CCC-BE92-7FA940B5F67C"

    private func request(_ tool: String, _ args: [String: Any]) throws -> RemindersPrivate.Request {
        try RemindersPrivate.request(tool: tool, arguments: args)
    }

    private func assertFails(
        _ tool: String,
        _ args: [String: Any],
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try request(tool, args), file: file, line: line) { error in
            XCTAssertEqual((error as? RemindersInputError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    // MARK: - Setting and gate

    func testSettingIsOffUntilChosen() {
        let defaults = UserDefaults(suiteName: "RemindersPrivateTests.\(UUID().uuidString)")!
        XCTAssertFalse(RemindersPrivate.isEnabled(defaults: defaults))
        defaults.set(true, forKey: RemindersPrivate.settingKey)
        XCTAssertTrue(RemindersPrivate.isEnabled(defaults: defaults))
    }

    func testRunRefusesWhileSettingIsOff() async {
        let defaults = UserDefaults(suiteName: "RemindersPrivateTests.\(UUID().uuidString)")!
        do {
            _ = try await RemindersPrivate.run(
                tool: "reminders_flag",
                arguments: ["id": id1, "flagged": true],
                defaults: defaults
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? RemindersInputError)?.code, "private_disabled")
        }
    }

    func testRunValidatesBeforeCallingTheBridge() async {
        let defaults = UserDefaults(suiteName: "RemindersPrivateTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: RemindersPrivate.settingKey)
        do {
            _ = try await RemindersPrivate.run(tool: "reminders_flag", arguments: ["id": "nope"], defaults: defaults)
            XCTFail("expected a validation error")
        } catch {
            XCTAssertEqual((error as? RemindersInputError)?.code, "invalid_id")
        }
    }

    // MARK: - Tags

    func testTagCleaning() throws {
        XCTAssertEqual(try RemindersPrivate.cleanTag("  #work "), "work")
        XCTAssertEqual(try RemindersPrivate.cleanTag("##x"), "x")
        XCTAssertThrowsError(try RemindersPrivate.cleanTag("two words"))
        XCTAssertThrowsError(try RemindersPrivate.cleanTag("#"))
        XCTAssertThrowsError(try RemindersPrivate.cleanTag(5))
        XCTAssertThrowsError(try RemindersPrivate.cleanTag(String(repeating: "a", count: 65)))
    }

    func testTagsAddDedupesCaseInsensitively() throws {
        let r = try request("reminders_tags", ["action": "add", "id": id1, "tags": ["Work", "#work", "home"]])
        XCTAssertEqual(r.action, "tags")
        XCTAssertEqual(r.args["mode"] as? String, "add")
        XCTAssertEqual(r.args["tags"] as? [String], ["Work", "home"])
    }

    func testTagsSetMayBeEmptyButAddMayNot() throws {
        XCTAssertEqual(
            try request("reminders_tags", ["action": "set", "id": id1, "tags": []]).args["tags"] as? [String],
            []
        )
        assertFails("reminders_tags", ["action": "add", "id": id1, "tags": []], code: "invalid_tags")
        assertFails("reminders_tags", ["action": "remove", "id": id1], code: "missing_tags")
    }

    func testTagsClearTakesNoTags() throws {
        XCTAssertEqual(try request("reminders_tags", ["action": "clear", "id": id1]).args["mode"] as? String, "clear")
        assertFails("reminders_tags", ["action": "clear", "id": id1, "tags": ["a"]], code: "invalid_arguments")
    }

    func testTagsListNeedsAListAndNotBoth() throws {
        XCTAssertEqual(try request("reminders_tags", ["action": "list", "list": "Work"]).action, "tags.list")
        assertFails("reminders_tags", ["action": "list"], code: "missing_list")
        assertFails("reminders_tags", ["action": "list", "list": "Work", "list_id": id1], code: "conflicting_list")
        assertFails(
            "reminders_tags",
            ["action": "add", "id": id1, "tags": ["a"], "list": "Work"],
            code: "invalid_arguments"
        )
    }

    func testIdentifiersMustBeUUIDs() {
        assertFails(
            "reminders_tags",
            ["action": "clear", "id": "x-apple-reminderkit://REMCDReminder/1"],
            code: "invalid_id"
        )
        assertFails("reminders_tags", ["action": "clear"], code: "missing_id")
        assertFails("reminders_tags", ["action": "bogus", "id": id1], code: "invalid_action")
        assertFails("reminders_tags", ["action": "clear", "id": id1, "extra": 1], code: "unknown_property")
    }

    // MARK: - Links

    func testLinkValidation() throws {
        XCTAssertEqual(try RemindersPrivate.validatedLink("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(
            try RemindersPrivate.validatedLink("obsidian://open?vault=Notes&file=Plan"),
            "obsidian://open?vault=Notes&file=Plan"
        )
        for bad in [
            "file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "about:blank", "smb://host/share",
            "ftp://example.com/x",
            "ssh://example.com", "https://localhost/", "http://127.0.0.1/", "http://10.1.2.3/", "http://192.168.1.1/",
            "http://172.20.0.1/", "http://169.254.1.1/", "https://printer.local/", "http://[::1]/",
            "http://2130706433/",
            "not a url", "example.com",
        ] {
            XCTAssertThrowsError(try RemindersPrivate.validatedLink(bad), bad)
        }
        XCTAssertNoThrow(try RemindersPrivate.validatedLink("http://8.8.8.8/"))
        XCTAssertNoThrow(try RemindersPrivate.validatedLink("http://172.32.0.1/"))
    }

    func testAddLinkRequest() throws {
        let r = try request("reminders_add_link", ["id": id1, "url": "https://example.com"])
        XCTAssertEqual(r.action, "link.add")
        XCTAssertEqual(r.args["url"] as? String, "https://example.com")
        assertFails("reminders_add_link", ["id": id1, "url": "http://10.0.0.1"], code: "invalid_url")
        assertFails("reminders_add_link", ["id": id1], code: "missing_url")
    }

    // MARK: - Flags

    func testFlagNeedsAChangeAndRealBooleans() throws {
        let r = try request("reminders_flag", ["id": id1, "flagged": true, "urgent": false])
        XCTAssertEqual(r.args["flagged"] as? Bool, true)
        XCTAssertEqual(r.args["urgent"] as? Bool, false)
        assertFails("reminders_flag", ["id": id1], code: "missing_change")
        assertFails("reminders_flag", ["id": id1, "flagged": "yes"], code: "invalid_flagged")
        assertFails("reminders_flag", ["id": id1, "flagged": 1], code: "invalid_flagged")
    }

    // MARK: - Sections

    func testSectionRequests() throws {
        XCTAssertEqual(
            try request("reminders_sections", ["action": "list", "list": "Work"]).args["mode"] as? String,
            "list"
        )
        let create = try request("reminders_sections", ["action": "create", "list_id": id1, "name": "Next"])
        XCTAssertEqual(create.args["name"] as? String, "Next")
        let rename = try request(
            "reminders_sections",
            ["action": "rename", "list": "Work", "section": "Next", "name": "Later"]
        )
        XCTAssertEqual(rename.args["section"] as? String, "Next")
        let assign = try request("reminders_sections", ["action": "assign", "id": id1, "section_id": id2])
        XCTAssertEqual(assign.args["section_id"] as? String, id2)
        assertFails("reminders_sections", ["action": "create", "list": "Work"], code: "missing_name")
        assertFails("reminders_sections", ["action": "delete", "list": "Work"], code: "missing_section")
        assertFails(
            "reminders_sections",
            ["action": "delete", "list": "Work", "section": "A", "section_id": id2],
            code: "conflicting_section"
        )
        assertFails("reminders_sections", ["action": "assign", "id": id1], code: "missing_section")
    }

    // MARK: - Subtasks

    func testSubtaskRequests() throws {
        XCTAssertEqual(
            try request("reminders_subtasks", ["action": "create", "parent_id": id1, "title": " Draft "]).args["title"]
                as? String,
            "Draft"
        )
        let nest = try request("reminders_subtasks", ["action": "move", "id": id1, "parent_id": id2])
        XCTAssertEqual(nest.args["top_level"] as? Bool, false)
        let top = try request("reminders_subtasks", ["action": "move", "id": id1, "top_level": true])
        XCTAssertEqual(top.args["top_level"] as? Bool, true)
        XCTAssertNil(top.args["parent_id"])
        assertFails("reminders_subtasks", ["action": "move", "id": id1], code: "invalid_arguments")
        assertFails(
            "reminders_subtasks",
            ["action": "move", "id": id1, "parent_id": id2, "top_level": true],
            code: "invalid_arguments"
        )
        assertFails("reminders_subtasks", ["action": "create", "parent_id": id1], code: "missing_title")
    }

    // MARK: - List appearance

    func testAppearance() throws {
        XCTAssertEqual(
            try request("reminders_list_appearance", ["list": "Work", "icon": "education3"]).args["icon"] as? String,
            "education3"
        )
        XCTAssertEqual(
            try request("reminders_list_appearance", ["list_id": id1, "emoji": "🎯"]).args["emoji"] as? String,
            "🎯"
        )
        assertFails("reminders_list_appearance", ["list": "Work"], code: "invalid_arguments")
        assertFails(
            "reminders_list_appearance",
            ["list": "Work", "icon": "education3", "emoji": "🎯"],
            code: "invalid_arguments"
        )
        assertFails("reminders_list_appearance", ["list": "Work", "icon": "star.fill"], code: "invalid_icon")
        assertFails("reminders_list_appearance", ["list": "Work", "icon": "Education3"], code: "invalid_icon")
        assertFails("reminders_list_appearance", ["list": "Work", "emoji": "ab"], code: "invalid_emoji")
        assertFails("reminders_list_appearance", ["icon": "education3"], code: "missing_list")
    }

    func testEmojiAndEmblemChecks() {
        XCTAssertTrue(RemindersPrivate.isSingleEmoji("🎯"))
        XCTAssertTrue(RemindersPrivate.isSingleEmoji("👨‍👩‍👧"))
        XCTAssertFalse(RemindersPrivate.isSingleEmoji("a"))
        XCTAssertFalse(RemindersPrivate.isSingleEmoji("5"))
        XCTAssertFalse(RemindersPrivate.isSingleEmoji("🎯🎯"))
        XCTAssertTrue(RemindersPrivate.isEmblemName("education3"))
        XCTAssertFalse(RemindersPrivate.isEmblemName(""))
        XCTAssertFalse(RemindersPrivate.isEmblemName("3abc"))
    }

    // MARK: - Groups

    func testGroupRequests() throws {
        XCTAssertEqual(try request("reminders_groups", ["action": "list"]).args["mode"] as? String, "list")
        let create = try request("reminders_groups", ["action": "create", "name": "Writing", "add_lists": ["A", "B"]])
        XCTAssertEqual(create.args["add_lists"] as? [String], ["A", "B"])
        XCTAssertEqual(
            try request("reminders_groups", ["action": "rename", "group": "Writing", "name": "Drafts"]).args["name"]
                as? String,
            "Drafts"
        )
        let add = try request("reminders_groups", ["action": "add_list", "group_id": id1, "list": "Ideas"])
        XCTAssertEqual(add.args["list"] as? String, "Ideas")
        assertFails("reminders_groups", ["action": "create"], code: "missing_name")
        assertFails("reminders_groups", ["action": "create", "name": "G", "add_lists": []], code: "invalid_add_lists")
        assertFails("reminders_groups", ["action": "delete"], code: "missing_group")
        assertFails("reminders_groups", ["action": "add_list", "group": "G"], code: "missing_list")
    }

    // MARK: - Smart lists and templates

    func testSmartListRequests() throws {
        let tags = try request(
            "reminders_smart_lists",
            ["action": "create", "name": "Focus", "tags": ["#work", "deep"]]
        )
        let filter = tags.args["filter"] as? [String: Any]
        let inner = (filter?["hashtags"] as? [String: Any])?["hashtags"] as? [String: Any]
        XCTAssertEqual(inner?["operation"] as? String, "or")
        XCTAssertEqual(inner?["include"] as? [String], ["work", "deep"])
        XCTAssertEqual((inner?["exclude"] as? [String])?.count, 0)
        let raw = try request(
            "reminders_smart_lists",
            ["action": "create", "name": "Raw", "filter": ["flagged": ["flagged": true]]]
        )
        XCTAssertNotNil(raw.args["filter"] as? [String: Any])
        assertFails("reminders_smart_lists", ["action": "create", "name": "x"], code: "invalid_arguments")
        assertFails(
            "reminders_smart_lists",
            ["action": "create", "name": "x", "tags": ["a"], "filter": ["a": 1]],
            code: "invalid_arguments"
        )
        assertFails(
            "reminders_smart_lists",
            ["action": "create", "name": "x", "filter": [String: Any]()],
            code: "invalid_filter"
        )
        XCTAssertEqual(
            try request("reminders_smart_lists", ["action": "delete", "smart_list": "Focus"]).args["smart_list"]
                as? String,
            "Focus"
        )
        assertFails("reminders_smart_lists", ["action": "delete"], code: "missing_smart_list")
    }

    func testTemplateRequests() throws {
        let create = try request("reminders_templates", ["action": "create", "name": "Packing", "list": "Trip"])
        XCTAssertEqual(create.args["include_completed"] as? Bool, false)
        XCTAssertEqual(
            try request(
                "reminders_templates",
                ["action": "create", "name": "P", "list_id": id1, "include_completed": true]
            ).args["include_completed"] as? Bool,
            true
        )
        XCTAssertEqual(
            try request("reminders_templates", ["action": "apply", "template_id": id1]).args["template_id"] as? String,
            id1
        )
        assertFails("reminders_templates", ["action": "create", "name": "P"], code: "missing_list")
        assertFails("reminders_templates", ["action": "apply"], code: "missing_template")
        assertFails(
            "reminders_templates",
            ["action": "delete", "template": "A", "template_id": id1],
            code: "conflicting_template"
        )
    }

    func testRestoreAndGetRequests() throws {
        XCTAssertEqual(try request("reminders_restore", ["id": id1, "list": "Work"]).args["list"] as? String, "Work")
        XCTAssertNil(try request("reminders_restore", ["id": id1]).args["list"])
        XCTAssertEqual(try request("reminders_get_private", ["id": id1]).action, "reminder.info")
        assertFails("reminders_nope", [:], code: "unknown_tool")
    }

    // MARK: - Responses

    func testParseSuccessAndError() throws {
        let ok = try RemindersPrivate.parse(response: #"{"ok":true,"result":{"verified":true,"tags":["a"]}}"#)
        XCTAssertEqual(ok["tags"] as? [String], ["a"])
        XCTAssertThrowsError(
            try RemindersPrivate.parse(
                response: #"{"ok":false,"error":{"code":"reminderkit_changed","message":"gone"}}"#
            )
        ) { error in
            XCTAssertEqual((error as? RemindersInputError)?.code, "reminderkit_changed")
            XCTAssertEqual((error as? RemindersInputError)?.message, "gone")
        }
        XCTAssertThrowsError(try RemindersPrivate.parse(response: "")) { error in
            XCTAssertEqual((error as? RemindersInputError)?.code, "bridge_failed")
        }
        XCTAssertThrowsError(try RemindersPrivate.parse(response: "[1]"))
    }

    func testShapeAddsVerifiedAndWarnsOnWrites() {
        let good = RemindersPrivate.shape(["verified": true], isWrite: true)
        XCTAssertEqual(good["verified"] as? Bool, true)
        XCTAssertNil(good["warning"])
        let bad = RemindersPrivate.shape(["verified": false], isWrite: true)
        XCTAssertEqual(bad["verified"] as? Bool, false)
        XCTAssertNotNil(bad["warning"])
        let missing = RemindersPrivate.shape([:], isWrite: true)
        XCTAssertEqual(missing["verified"] as? Bool, false)
        let read = RemindersPrivate.shape(["tags": []], isWrite: false)
        XCTAssertNil(read["verified"])
    }

    func testWhichCallsWrite() {
        XCTAssertFalse(RemindersPrivate.isWrite(tool: "reminders_get_private", arguments: [:]))
        XCTAssertFalse(RemindersPrivate.isWrite(tool: "reminders_tags", arguments: ["action": "list"]))
        XCTAssertTrue(RemindersPrivate.isWrite(tool: "reminders_tags", arguments: ["action": "add"]))
        XCTAssertFalse(RemindersPrivate.isWrite(tool: "reminders_groups", arguments: ["action": "list"]))
        XCTAssertTrue(RemindersPrivate.isWrite(tool: "reminders_flag", arguments: [:]))
        XCTAssertTrue(RemindersPrivate.isWrite(tool: "reminders_restore", arguments: [:]))
    }

    func testRequestJSONIsSortedAndValid() throws {
        let r = RemindersPrivate.Request(action: "flags", args: ["id": id1, "flagged": true])
        XCTAssertEqual(r.json, #"{"action":"flags","args":{"flagged":true,"id":"\#(id1)"}}"#)
    }
}
