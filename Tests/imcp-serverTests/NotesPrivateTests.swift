import Foundation
import XCTest

final class NotesPrivateTests: XCTestCase {
    private let id = "x-coredata://6B2B2A52-1111-2222-3333-444455556666/ICNote/p123"
    private let other = "x-coredata://6B2B2A52-1111-2222-3333-444455556666/ICNote/p456"

    private func request(_ tool: String, _ args: [String: Any]) throws -> NotesPrivate.Request {
        try NotesPrivate.request(tool: tool, arguments: args)
    }

    private func failure(_ tool: String, _ args: [String: Any]) -> NotesPrivate.Failure? {
        do {
            _ = try request(tool, args)
            return nil
        } catch { return error as? NotesPrivate.Failure }
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "NotesPrivateTests.\(UUID().uuidString)")!
    }

    // MARK: Gates

    func testPrivateFeaturesAreOffByDefault() {
        let defaults = suite()
        XCTAssertFalse(NotesPrivate.isEnabled(defaults: defaults))
        defaults.set(true, forKey: NotesPrivate.settingKey)
        XCTAssertTrue(NotesPrivate.isEnabled(defaults: defaults))
    }

    func testRunRefusesWhileOff() async {
        do {
            _ = try await NotesPrivate.run(tool: "notes_structure", arguments: ["id": id], defaults: suite())
            XCTFail("expected a refusal")
        } catch let error as NotesPrivate.Failure {
            XCTAssertEqual(error.code, "private_disabled")
            XCTAssertTrue(error.message.contains("Private Notes features"))
        } catch { XCTFail("\(error)") }
    }

    func testWritesNeedTheChangeSettingToo() async {
        let defaults = suite()
        defaults.set(true, forKey: NotesPrivate.settingKey)
        do {
            _ = try await NotesPrivate.run(
                tool: "notes_pin",
                arguments: ["id": id, "pinned": true],
                defaults: defaults
            )
            XCTFail("expected a refusal")
        } catch let error as NotesPrivate.Failure {
            XCTAssertEqual(error.code, "writes_disabled")
        } catch { XCTFail("\(error)") }
    }

    func testReadsDoNotNeedTheChangeSetting() async {
        let defaults = suite()
        defaults.set(true, forKey: NotesPrivate.settingKey)
        do {
            // Gets past both gates and reaches the bridge, which is not in the test target.
            _ = try await NotesPrivate.run(tool: "notes_structure", arguments: ["id": id], defaults: defaults)
            XCTFail("expected bridge_missing")
        } catch let error as NotesPrivate.Failure {
            XCTAssertEqual(error.code, "bridge_missing")
        } catch { XCTFail("\(error)") }
    }

    func testValidationHappensBeforeTheBridge() async {
        let defaults = suite()
        defaults.set(true, forKey: NotesPrivate.settingKey)
        defaults.set(true, forKey: NotesWriteTools.settingKey)
        do {
            _ = try await NotesPrivate.run(
                tool: "notes_pin",
                arguments: ["id": "nope", "pinned": true],
                defaults: defaults
            )
            XCTFail("expected invalid_id")
        } catch let error as NotesPrivate.Failure {
            XCTAssertEqual(error.code, "invalid_id")
        } catch { XCTFail("\(error)") }
    }

    func testToolListingFollowsTheSettings() {
        XCTAssertFalse(NotesPrivate.isListed("notes_tags", privateEnabled: false, writesEnabled: true))
        XCTAssertTrue(NotesPrivate.isListed("notes_tags", privateEnabled: true, writesEnabled: false))
        XCTAssertFalse(NotesPrivate.isListed("notes_pin", privateEnabled: true, writesEnabled: false))
        XCTAssertTrue(NotesPrivate.isListed("notes_pin", privateEnabled: true, writesEnabled: true))
        XCTAssertFalse(NotesPrivate.isListed("notes_create_markdown", privateEnabled: true, writesEnabled: false))
        XCTAssertTrue(NotesPrivate.isListed("notes_get", privateEnabled: false, writesEnabled: false))
    }

    func testWhichCallsWrite() {
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_structure", arguments: [:]))
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_tags", arguments: ["action": "list"]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_tags", arguments: ["action": "add"]))
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_checklist", arguments: ["action": "get"]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_checklist", arguments: ["action": "set"]))
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_table", arguments: ["action": "get"]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_table", arguments: ["action": "create"]))
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_link", arguments: ["action": "get"]))
        XCTAssertFalse(NotesPrivate.isWrite(tool: "notes_link", arguments: ["action": "list"]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_link", arguments: ["action": "insert"]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_pin", arguments: [:]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_append_rich", arguments: [:]))
        XCTAssertTrue(NotesPrivate.isWrite(tool: "notes_create_markdown", arguments: [:]))
    }

    // MARK: Note ids

    func testNoteIdentifierForms() throws {
        XCTAssertEqual(try NotesPrivate.noteIdentifier(id), id)
        let uuid = "8F3C2D10-1111-4222-8333-444455556666"
        XCTAssertEqual(try NotesPrivate.noteIdentifier(uuid), uuid)
        XCTAssertEqual(try NotesPrivate.noteIdentifier("notes://showNote?identifier=\(uuid)"), uuid)
        XCTAssertEqual(try NotesPrivate.noteIdentifier("  \(uuid)\n"), uuid)
        XCTAssertThrowsError(try NotesPrivate.noteIdentifier("x-coredata://X/ICFolder/p1"))
        XCTAssertThrowsError(try NotesPrivate.noteIdentifier("hello"))
        XCTAssertThrowsError(try NotesPrivate.noteIdentifier("notes://showNote?identifier=nope"))
    }

    func testUnknownPropertiesAreRefused() {
        XCTAssertEqual(failure("notes_pin", ["id": id, "pinned": true, "extra": 1])?.code, "unknown_property")
        XCTAssertEqual(failure("notes_nope", [:])?.code, "unknown_tool")
    }

    // MARK: Structure and pin

    func testStructureRequest() throws {
        let r = try request("notes_structure", ["id": id, "blocks": true])
        XCTAssertEqual(r.action, "structure")
        XCTAssertEqual(r.args["id"] as? String, id)
        XCTAssertEqual(r.args["blocks"] as? Bool, true)
        XCTAssertEqual(try request("notes_structure", ["id": id]).args["blocks"] as? Bool, false)
    }

    func testPinRequest() throws {
        let r = try request("notes_pin", ["id": id, "pinned": false, "expected_pinned": true])
        XCTAssertEqual(r.action, "pin")
        XCTAssertEqual(r.args["pinned"] as? Bool, false)
        XCTAssertEqual(r.args["expectedPinned"] as? Bool, true)
        XCTAssertEqual(failure("notes_pin", ["id": id])?.code, "missing_pinned")
        XCTAssertEqual(failure("notes_pin", ["id": id, "pinned": "yes"])?.code, "invalid_pinned")
    }

    // MARK: Tags

    func testTagCleaning() throws {
        XCTAssertEqual(try NotesPrivate.cleanTag("#work"), "work")
        XCTAssertEqual(try NotesPrivate.cleanTag("  ##a  "), "a")
        XCTAssertThrowsError(try NotesPrivate.cleanTag("two words"))
        XCTAssertThrowsError(try NotesPrivate.cleanTag("#"))
        XCTAssertThrowsError(try NotesPrivate.cleanTag(String(repeating: "x", count: 65)))
        XCTAssertThrowsError(try NotesPrivate.cleanTag(5))
    }

    func testTagAddDeduplicatesIgnoringCase() throws {
        let r = try request("notes_tags", ["action": "add", "id": id, "tags": ["#A", "a", "b"]])
        XCTAssertEqual(r.action, "tags.change")
        XCTAssertEqual(r.args["mode"] as? String, "add")
        XCTAssertEqual(r.args["tags"] as? [String], ["A", "b"])
    }

    func testTagListScopes() throws {
        XCTAssertEqual(try request("notes_tags", ["action": "list"]).args.count, 0)
        XCTAssertEqual(try request("notes_tags", ["action": "list", "id": id]).args["id"] as? String, id)
        let folder = try request("notes_tags", ["action": "list", "folder": "Work/Clients", "account": "iCloud"])
        XCTAssertEqual(folder.args["folder"] as? String, "Work/Clients")
        XCTAssertEqual(folder.args["account"] as? String, "iCloud")
        XCTAssertEqual(failure("notes_tags", ["action": "list", "id": id, "folder": "x"])?.code, "conflicting_scope")
        XCTAssertEqual(failure("notes_tags", ["action": "list", "account": "iCloud"])?.code, "invalid_arguments")
        XCTAssertEqual(failure("notes_tags", ["action": "list", "tags": ["a"]])?.code, "invalid_arguments")
    }

    func testTagAddNeedsTagsAndOneNote() {
        XCTAssertEqual(failure("notes_tags", ["action": "add", "id": id])?.code, "missing_tags")
        XCTAssertEqual(failure("notes_tags", ["action": "add", "id": id, "tags": []])?.code, "invalid_tags")
        XCTAssertEqual(failure("notes_tags", ["action": "remove", "tags": ["a"]])?.code, "missing_id")
        XCTAssertEqual(
            failure("notes_tags", ["action": "add", "id": id, "tags": ["a"], "ids": [other]])?.code,
            "invalid_arguments"
        )
        XCTAssertEqual(failure("notes_tags", ["action": "clear", "id": id])?.code, "invalid_action")
    }

    func testTagReplaceRequest() throws {
        let r = try request("notes_tags", ["action": "replace", "ids": [id, other], "old": "#old", "new": "new"])
        XCTAssertEqual(r.args["mode"] as? String, "replace")
        XCTAssertEqual(r.args["ids"] as? [String], [id, other])
        XCTAssertEqual(r.args["old"] as? String, "old")
        XCTAssertEqual(r.args["new"] as? String, "new")
        let single = try request("notes_tags", ["action": "replace", "id": id, "old": "a", "new": "b"])
        XCTAssertEqual(single.args["ids"] as? [String], [id])
        XCTAssertEqual(failure("notes_tags", ["action": "replace", "ids": [id]])?.code, "missing_tags")
        XCTAssertEqual(failure("notes_tags", ["action": "replace", "old": "a", "new": "b"])?.code, "missing_id")
        XCTAssertEqual(
            failure("notes_tags", ["action": "replace", "ids": [], "old": "a", "new": "b"])?.code,
            "invalid_ids"
        )
        XCTAssertEqual(
            failure("notes_tags", ["action": "replace", "ids": [id], "old": "a b", "new": "c"])?.code,
            "invalid_tags"
        )
    }

    // MARK: Checklist

    func testChecklistAdd() throws {
        let r = try request(
            "notes_checklist",
            ["action": "add", "id": id, "items": ["  Milk ", "Eggs"], "done": true]
        )
        XCTAssertEqual(r.action, "checklist.add")
        XCTAssertEqual(r.args["items"] as? [String], ["Milk", "Eggs"])
        XCTAssertEqual(r.args["done"] as? Bool, true)
        XCTAssertEqual(
            try request("notes_checklist", ["action": "add", "id": id, "items": ["a"]]).args["done"] as? Bool,
            false
        )
    }

    func testChecklistItemLimits() {
        XCTAssertEqual(failure("notes_checklist", ["action": "add", "id": id, "items": []])?.code, "invalid_items")
        XCTAssertEqual(
            failure("notes_checklist", ["action": "add", "id": id, "items": ["a\nb"]])?.code,
            "invalid_items"
        )
        XCTAssertEqual(failure("notes_checklist", ["action": "add", "id": id, "items": ["  "]])?.code, "invalid_items")
        XCTAssertEqual(
            failure("notes_checklist", ["action": "add", "id": id, "items": Array(repeating: "x", count: 21)])?.code,
            "invalid_items"
        )
        XCTAssertEqual(
            failure("notes_checklist", ["action": "add", "id": id, "items": [String(repeating: "x", count: 1001)]])?
                .code,
            "invalid_items"
        )
        XCTAssertNil(
            failure("notes_checklist", ["action": "add", "id": id, "items": Array(repeating: "x", count: 20)])
        )
    }

    func testChecklistSet() throws {
        let byIndex = try request("notes_checklist", ["action": "set", "id": id, "index": 2, "done": true])
        XCTAssertEqual(byIndex.action, "checklist.set")
        XCTAssertEqual(byIndex.args["index"] as? Int, 2)
        XCTAssertEqual(byIndex.args["done"] as? Bool, true)
        let byText = try request("notes_checklist", ["action": "set", "id": id, "text": "Milk", "done": false])
        XCTAssertEqual(byText.args["text"] as? String, "Milk")
        XCTAssertEqual(failure("notes_checklist", ["action": "set", "id": id, "done": true])?.code, "missing_item")
        XCTAssertEqual(failure("notes_checklist", ["action": "set", "id": id, "index": 1])?.code, "missing_done")
        XCTAssertEqual(
            failure("notes_checklist", ["action": "set", "id": id, "index": 1, "text": "a", "done": true])?.code,
            "conflicting_item"
        )
        XCTAssertEqual(
            failure("notes_checklist", ["action": "set", "id": id, "index": -1, "done": true])?.code,
            "invalid_index"
        )
        XCTAssertEqual(
            failure("notes_checklist", ["action": "set", "id": id, "index": 1.5, "done": true])?.code,
            "invalid_index"
        )
        XCTAssertEqual(
            failure("notes_checklist", ["action": "set", "id": id, "items": ["a"], "done": true])?.code,
            "invalid_arguments"
        )
    }

    func testChecklistGetTakesOnlyId() throws {
        XCTAssertEqual(try request("notes_checklist", ["action": "get", "id": id]).action, "checklist.get")
        XCTAssertEqual(
            failure("notes_checklist", ["action": "get", "id": id, "done": true])?.code,
            "invalid_arguments"
        )
    }

    // MARK: Tables

    func testTableRows() throws {
        let r = try request("notes_table", ["action": "create", "id": id, "rows": [["a", "b"], ["c", ""]]])
        XCTAssertEqual(r.action, "table.create")
        XCTAssertEqual(r.args["rows"] as? [[String]], [["a", "b"], ["c", ""]])
    }

    func testTableRowValidation() {
        func code(_ rows: Any) -> String? {
            failure("notes_table", ["action": "create", "id": id, "rows": rows])?.code
        }
        XCTAssertEqual(code([]), "invalid_rows")
        XCTAssertEqual(code([[]]), "invalid_rows")
        XCTAssertEqual(code([["a"], ["b", "c"]]), "invalid_rows")
        XCTAssertEqual(code([["a\tb"]]), "invalid_rows")
        XCTAssertEqual(code([["a\nb"]]), "invalid_rows")
        XCTAssertEqual(code([[1]]), "invalid_rows")
        XCTAssertEqual(code([Array(repeating: "x", count: 101)]), "invalid_rows")
        XCTAssertEqual(code(Array(repeating: ["x"], count: 1001)), "invalid_rows")
        XCTAssertNil(code(Array(repeating: ["x"], count: 1000)))
        XCTAssertEqual(failure("notes_table", ["action": "create", "id": id])?.code, "invalid_rows")
        XCTAssertEqual(failure("notes_table", ["action": "get", "id": id, "rows": [["a"]]])?.code, "invalid_arguments")
    }

    // MARK: Links

    func testLinkRequests() throws {
        XCTAssertEqual(try request("notes_link", ["action": "get", "id": id]).action, "link.get")
        XCTAssertEqual(try request("notes_link", ["action": "list", "id": id]).action, "link.list")
        let insert = try request("notes_link", ["action": "insert", "id": id, "target": other, "label": "See this"])
        XCTAssertEqual(insert.action, "link.insert")
        XCTAssertEqual(insert.args["target"] as? String, other)
        XCTAssertEqual(insert.args["label"] as? String, "See this")
        XCTAssertEqual(failure("notes_link", ["action": "insert", "id": id])?.code, "missing_target")
        XCTAssertEqual(failure("notes_link", ["action": "get", "id": id, "target": other])?.code, "invalid_arguments")
        XCTAssertEqual(
            failure("notes_link", ["action": "insert", "id": id, "target": other, "label": "a\nb"])?.code,
            "invalid_label"
        )
    }

    // MARK: Append and Markdown

    func testAppendKeepsContentUntrimmed() throws {
        let r = try request("notes_append_rich", ["id": id, "content": "  line one\nline two\n", "format": "markdown"])
        XCTAssertEqual(r.action, "append")
        XCTAssertEqual(r.args["content"] as? String, "  line one\nline two\n")
        XCTAssertEqual(r.args["format"] as? String, "markdown")
        XCTAssertEqual(
            try request("notes_append_rich", ["id": id, "content": "x"]).args["format"] as? String,
            "plaintext"
        )
        XCTAssertEqual(
            failure("notes_append_rich", ["id": id, "content": "x", "format": "html"])?.code,
            "invalid_format"
        )
        XCTAssertEqual(failure("notes_append_rich", ["id": id, "content": " \n "])?.code, "missing_content")
        XCTAssertEqual(
            failure("notes_append_rich", ["id": id, "content": String(repeating: "x", count: 200_001)])?.code,
            "invalid_content"
        )
    }

    func testCreateMarkdownTitleBecomesAHeadingOnlyWhenNeeded() throws {
        XCTAssertEqual(NotesPrivate.createMarkdownBody(title: "T", markdown: "body"), "# T\n\nbody")
        XCTAssertEqual(NotesPrivate.createMarkdownBody(title: "T", markdown: "\n# Own\n\nbody"), "\n# Own\n\nbody")
        let r = try request(
            "notes_create_markdown",
            ["markdown": "text", "title": "Plan", "folder": "Work/Docs", "account": "iCloud"]
        )
        XCTAssertEqual(r.action, "create_markdown")
        XCTAssertEqual(r.args["markdown"] as? String, "# Plan\n\ntext")
        XCTAssertEqual(r.args["folder"] as? String, "Work/Docs")
        XCTAssertEqual(r.args["account"] as? String, "iCloud")
        XCTAssertEqual(failure("notes_create_markdown", ["markdown": "x", "title": "a\nb"])?.code, "invalid_title")
        XCTAssertEqual(failure("notes_create_markdown", [:])?.code, "missing_markdown")
    }

    // MARK: Request JSON and responses

    func testRequestJSONIsStable() throws {
        let r = try request("notes_pin", ["id": id, "pinned": true])
        let object = try JSONSerialization.jsonObject(with: Data(r.json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["action"] as? String, "pin")
        XCTAssertEqual((object?["args"] as? [String: Any])?["id"] as? String, id)
    }

    func testParseSuccessAndFailure() throws {
        let ok = try NotesPrivate.parse(response: #"{"ok":true,"result":{"verified":true,"id":"x"}}"#)
        XCTAssertEqual(ok["id"] as? String, "x")
        XCTAssertThrowsError(
            try NotesPrivate.parse(response: #"{"ok":false,"error":{"code":"not_found","message":"No note"}}"#)
        ) { error in
            XCTAssertEqual((error as? NotesPrivate.Failure)?.code, "not_found")
            XCTAssertEqual((error as? NotesPrivate.Failure)?.message, "No note")
        }
        XCTAssertThrowsError(try NotesPrivate.parse(response: "")) { error in
            XCTAssertEqual((error as? NotesPrivate.Failure)?.code, "bridge_failed")
        }
        XCTAssertThrowsError(try NotesPrivate.parse(response: "not json"))
    }

    func testShapeReportsVerifiedAndWarns() {
        let good = NotesPrivate.shape(["verified": true], isWrite: true)
        XCTAssertEqual(good["verified"] as? Bool, true)
        XCTAssertNil(good["warning"])
        let bad = NotesPrivate.shape(["verified": false], isWrite: true)
        XCTAssertEqual(bad["verified"] as? Bool, false)
        XCTAssertNotNil(bad["warning"])
        let missing = NotesPrivate.shape([:], isWrite: true)
        XCTAssertEqual(missing["verified"] as? Bool, false)
        XCTAssertNotNil(missing["warning"])
        let read = NotesPrivate.shape(["tags": []], isWrite: false)
        XCTAssertNil(read["verified"])
        XCTAssertNil(read["warning"])
    }
}
