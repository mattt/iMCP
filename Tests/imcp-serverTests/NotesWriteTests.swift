import Foundation
import MCP
import XCTest
import os

/// These tests send no Apple events to Notes or any other app.
final class NotesWriteTests: XCTestCase {
    // MARK: - Markdown

    private func html(_ markdown: String) -> String {
        NotesMarkdown.html(from: markdown)
    }

    func testParagraphsKeepTheirLinesAndSeparateBlocks() {
        XCTAssertEqual(html("one\ntwo\n\nthree"), "<div>one<br>two</div><div><br></div><div>three</div>")
    }

    func testTextIsEscapedSoThatItCannotBecomeMarkup() {
        XCTAssertEqual(
            html("a <script>alert(1)</script> & b"),
            "<div>a &lt;script&gt;alert(1)&lt;/script&gt; &amp; b</div>"
        )
        XCTAssertEqual(html("`<b>`"), "<div><tt>&lt;b&gt;</tt></div>")
    }

    func testEmphasis() {
        XCTAssertEqual(
            html("**bold** and *italic* and _also_ and ~~gone~~"),
            "<div><b>bold</b> and <i>italic</i> and <i>also</i> and <s>gone</s></div>"
        )
        XCTAssertEqual(html("use snake_case_names and 2 * 3 * 4"), "<div>use snake_case_names and 2 * 3 * 4</div>")
        XCTAssertEqual(html(#"\*literal\*"#), "<div>*literal*</div>")
    }

    func testLinksKeepTheirAddressesInTheText() {
        XCTAssertEqual(html("[iMCP](https://imcp.app)"), "<div>iMCP (https://imcp.app)</div>")
        XCTAssertEqual(html("[https://a.example](https://a.example)"), "<div>https://a.example</div>")
        XCTAssertEqual(html("![a chart](chart.png)"), "<div>a chart (chart.png)</div>")
        XCTAssertEqual(html("[**x**](https://e.com?a=1&b=2)"), "<div><b>x</b> (https://e.com?a=1&amp;b=2)</div>")
    }

    func testHeadingsStartBelowTheTitle() {
        XCTAssertEqual(html("# One\n## Two\n### Three"), "<h2>One</h2><h2>Two</h2><h3>Three</h3>")
        XCTAssertEqual(html("#NotAHeading"), "<div>#NotAHeading</div>")
    }

    func testBulletsNestAsNotesWritesThem() {
        XCTAssertEqual(html("- a\n- b\n  - c\n- d"), "<ul><li>a</li><li>b</li><ul><li>c</li></ul><li>d</li></ul>")
    }

    func testChecklistsBecomeBulletsThatKeepTheirState() {
        XCTAssertEqual(html("- [ ] todo\n- [x] done"), "<ul><li>☐ todo</li><li>☑ done</li></ul>")
    }

    func testNumberedItemsKeepTheirNumbersAsText() {
        XCTAssertEqual(html("1. one\n2. two"), "<div>1. one</div><div>2. two</div>")
        XCTAssertEqual(html("- a\n1. one"), "<ul><li>a</li></ul><div>1. one</div>")
    }

    func testAListIsFollowedByAnEmptyLine() {
        XCTAssertEqual(html("- a\n\nafter"), "<ul><li>a</li></ul><div><br></div><div>after</div>")
        XCTAssertEqual(html("- a"), "<ul><li>a</li></ul>")
    }

    func testCodeBlocksKeepEveryLineUnformatted() {
        XCTAssertEqual(
            html("```swift\nlet a = *1*\n\nlet b\n```"),
            "<div><tt>let a = *1*</tt></div><div><br></div><div><tt>let b</tt></div>"
        )
    }

    func testQuotesKeepTheirMarker() {
        XCTAssertEqual(html("> quoted **text**"), "<div>&gt; quoted <b>text</b></div>")
    }

    func testTables() {
        XCTAssertEqual(
            html("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 |"),
            "<table><tbody><tr><td><b>a</b></td><td><b>b</b></td></tr><tr><td>1</td><td>2</td></tr><tr><td>3</td><td></td></tr></tbody></table>"
        )
        XCTAssertEqual(html("a | b"), "<div>a | b</div>")
    }

    func testUnterminatedMarkdownStaysText() {
        XCTAssertEqual(html("**open and `code and [link"), "<div>**open and `code and [link</div>")
    }

    func testPlainTextBecomesEscapedParagraphs() {
        XCTAssertEqual(
            NotesHTML.html(fromPlainText: "a < b\r\n\r\nc"),
            "<div>a &lt; b</div><div><br></div><div>c</div>"
        )
    }

    // MARK: - Validation

    func testFolderPaths() throws {
        XCTAssertEqual(try NotesFolderPath.parse("Work").components, ["Work"])
        XCTAssertEqual(try NotesFolderPath.parse(" Work / Projects/2026 ").components, ["Work", "Projects", "2026"])
        for invalid in ["", "/", "/Work", "Work/", "Work//Projects", " / ", "A\nB", "A/B\u{7}"] {
            XCTAssertThrowsError(try NotesFolderPath.parse(invalid), "\(invalid.debugDescription)")
        }
        XCTAssertThrowsError(try NotesFolderPath.parse(Array(repeating: "a", count: 11).joined(separator: "/")))
        XCTAssertNoThrow(try NotesFolderPath.parse(Array(repeating: "a", count: 10).joined(separator: "/")))
        XCTAssertThrowsError(try NotesFolderPath.parse(String(repeating: "a", count: 201)))
    }

    private func request(
        title: String = "T",
        body: String = "",
        format: NotesContentFormat = .plaintext,
        folder: String? = nil,
        account: String? = nil,
        create: Bool = false
    ) throws -> NotesNoteRequest {
        try NotesNoteRequest(
            title: title,
            body: body,
            format: format,
            folder: folder,
            account: account,
            createMissingFolders: create
        )
    }

    func testTitlesAreOneLineAndBounded() throws {
        XCTAssertEqual(try request(title: "  Plan  ").title, "Plan")
        for invalid in ["", "   ", "a\nb", "a\u{0}b", String(repeating: "x", count: 251)] {
            XCTAssertThrowsError(try request(title: invalid), "\(invalid.debugDescription)")
        }
    }

    func testBodiesAreBounded() throws {
        XCTAssertNoThrow(try request(body: String(repeating: "x", count: NotesWriteInput.maximumBodyLength)))
        XCTAssertThrowsError(try request(body: String(repeating: "x", count: NotesWriteInput.maximumBodyLength + 1)))
    }

    func testAccountsAreNotEmpty() {
        XCTAssertThrowsError(try request(account: ""))
        XCTAssertThrowsError(try request(account: "i\nCloud"))
        XCTAssertEqual(try? request(account: " iCloud ").account, "iCloud")
    }

    func testTheTitleLeadsTheNote() throws {
        XCTAssertEqual(
            try request(title: "A & <B>", body: "x", format: .plaintext).bodyHTML,
            "<div><h1>A &amp; &lt;B&gt;</h1></div><div>x</div>"
        )
        XCTAssertEqual(
            try request(title: "T", body: "**x**", format: .markdown).bodyHTML,
            "<div><h1>T</h1></div><div><b>x</b></div>"
        )
        XCTAssertEqual(
            try request(title: "T", body: "<p>raw</p>", format: .html).bodyHTML,
            "<div><h1>T</h1></div><p>raw</p>"
        )
        XCTAssertEqual(try request(title: "T").bodyHTML, "<div><h1>T</h1></div>")
    }

    func testFolderNamesCannotHoldASeparator() throws {
        XCTAssertEqual(
            try NotesFolderRequest(name: " Ideas ", parent: "Work/Projects", account: nil).parent.components,
            ["Work", "Projects"]
        )
        XCTAssertThrowsError(try NotesFolderRequest(name: "a/b", parent: nil, account: nil))
        XCTAssertThrowsError(try NotesFolderRequest(name: "", parent: nil, account: nil))
        XCTAssertThrowsError(try NotesFolderRequest(name: "a", parent: "x//y", account: nil))
    }

    // MARK: - Passing arguments to the script

    /// Text that would change a script if it were part of the script's source.
    private let hostile = [
        "\" & (do shell script \"touch /tmp/injected\") & \"",
        "\\\" end tell\ntell application \"Finder\" to delete every item\n",
        "line one\rline two\ttab \u{2028} “smart” 日本語 🎉",
        "on run\nreturn 1\nend run",
    ]

    func testValuesReachAHandlerUnchanged() async throws {
        let script = """
            on echo(one, two, flag)
            	return {one, two, flag}
            end echo
            """
        for text in hostile {
            let result = try await NSAppleScript.execute(
                script,
                calling: .init("echo", [.string(text), .strings([text, "b"]), .boolean(true)])
            )
            XCTAssertEqual(result.atIndex(1)?.stringValue, text)
            XCTAssertEqual(result.atIndex(2)?.atIndex(1)?.stringValue, text)
            XCTAssertEqual(result.atIndex(2)?.atIndex(2)?.stringValue, "b")
            XCTAssertEqual(result.atIndex(3)?.booleanValue, true)
        }
    }

    func testAHandlerNameKeepsItsCaseInTheScript() async throws {
        let result = try await NSAppleScript.execute(
            "on createNote(a)\nreturn a\nend createNote",
            calling: .init("createNote", [.string("x")])
        )
        XCTAssertEqual(result.stringValue, "x")
    }

    func testRequestsPassEveryValueAsAParameter() throws {
        // A folder name can't contain "/", which a path would split on.
        let text = #"" & (do shell script "id") & ""#
        let note = try request(
            title: text,
            body: text,
            format: .markdown,
            folder: "A/\(text)",
            account: text,
            create: true
        )
        let call = NotesScripts.createNote(note)
        XCTAssertEqual(call.name, "createNote")
        XCTAssertEqual(call.parameters.count, 4)
        XCTAssertEqual(call.parameters[0], .string(text))
        XCTAssertEqual(call.parameters[1], .strings(["A", text]))
        XCTAssertEqual(call.parameters[2], .string(note.bodyHTML))
        XCTAssertEqual(call.parameters[3], .boolean(true))
        XCTAssertFalse(NotesScripts.source.contains("do shell script"))

        let folder = try NotesFolderRequest(name: text, parent: "P", account: nil)
        let folderCall = NotesScripts.createFolder(folder)
        XCTAssertEqual(folderCall.parameters[0], .string(""))
        XCTAssertEqual(folderCall.parameters[1], .strings(["P"]))
        XCTAssertEqual(folderCall.parameters[2], .string(folder.name))
    }

    func testEveryHandlerTheToolsCallIsInTheScript() {
        for name in ["createNote", "createFolder", "resolveAccount", "resolveFolder", "findChild"] {
            XCTAssertTrue(NotesScripts.source.contains("on \(name)("), name)
        }
    }

    // MARK: - Tools

    private final class FakeRunner: NotesScriptRunning {
        private let calls = OSAllocatedUnfairLock(initialState: [NSAppleScript.Subroutine]())
        var recorded: [NSAppleScript.Subroutine] { calls.withLock { $0 } }

        func run(_ source: String, calling subroutine: NSAppleScript.Subroutine) async throws -> [String] {
            calls.withLock { $0.append(subroutine) }
            return subroutine.name == "createNote"
                ? ["x-coredata://1/ICNote/p7", "Plan", "Notes", "iCloud"]
                : ["x-coredata://1/ICFolder/p8", "Ideas", "iCloud"]
        }
    }

    private func tools(enabled: Bool, runner: FakeRunner = FakeRunner()) -> [String: Tool] {
        Dictionary(
            uniqueKeysWithValues: NotesWriteTools.tools(isEnabled: { enabled }, runner: runner).map { ($0.name, $0) }
        )
    }

    func testToolsAreNamedAndAnnotatedAsCreateOnly() {
        let tools = tools(enabled: true)
        XCTAssertEqual(Set(tools.keys), NotesWriteTools.toolNames)
        for tool in tools.values {
            XCTAssertEqual(tool.annotations.readOnlyHint, false, tool.name)
            XCTAssertEqual(tool.annotations.destructiveHint, false, tool.name)
            XCTAssertEqual(tool.annotations.openWorldHint, false, tool.name)
        }
    }

    func testToolsRefuseWhileChangesAreOff() async {
        let runner = FakeRunner()
        let tools = tools(enabled: false, runner: runner)
        for (name, arguments) in [
            ("notes_create", ["title": Value.string("T")]), ("notes_create_folder", ["name": Value.string("F")]),
        ] {
            do {
                _ = try await tools[name]!(arguments)
                XCTFail("\(name) ran while changes were off")
            } catch {
                XCTAssertEqual(error as? NotesWriteError, .writesDisabled)
                XCTAssertTrue("\(error)".contains("Allow iMCP to create notes and folders"))
            }
        }
        XCTAssertTrue(runner.recorded.isEmpty)
    }

    func testCreateRunsTheScriptWithTheCheckedRequest() async throws {
        let runner = FakeRunner()
        let result = try await tools(enabled: true, runner: runner)["notes_create"]!([
            "title": "Plan", "body": "- [ ] a", "format": "markdown", "folder": "Work/Ideas",
            "createMissingFolders": true,
        ])
        let call = try XCTUnwrap(runner.recorded.first)
        XCTAssertEqual(call.parameters[1], .strings(["Work", "Ideas"]))
        XCTAssertEqual(call.parameters[2], .string("<div><h1>Plan</h1></div><ul><li>☐ a</li></ul>"))
        XCTAssertEqual(call.parameters[3], .boolean(true))
        XCTAssertEqual(result.objectValue?["name"]?.stringValue, "Plan")
        XCTAssertEqual(result.objectValue?["folder"]?.stringValue, "Notes")
        XCTAssertEqual(result.objectValue?["identifier"]?.stringValue, "x-coredata://1/ICNote/p7")
    }

    func testCreateFolderRunsTheScript() async throws {
        let runner = FakeRunner()
        let result = try await tools(enabled: true, runner: runner)["notes_create_folder"]!(
            ["name": "Ideas", "parent": "Work", "account": "iCloud"])
        let call = try XCTUnwrap(runner.recorded.first)
        XCTAssertEqual(call.name, "createFolder")
        XCTAssertEqual(call.parameters, [.string("iCloud"), .strings(["Work"]), .string("Ideas")])
        XCTAssertEqual(result.objectValue?["name"]?.stringValue, "Ideas")
    }

    func testBadArgumentsRunNoScript() async {
        let runner = FakeRunner()
        let create = tools(enabled: true, runner: runner)["notes_create"]!
        for arguments: [String: Value] in [
            [:], ["title": 5], ["title": "T", "format": "rtf"], ["title": "T", "folder": "a//b"],
            ["title": "T", "createMissingFolders": "yes"], ["title": "a\nb"],
        ] {
            do {
                _ = try await create(arguments)
                XCTFail("accepted \(arguments)")
            } catch {
                XCTAssertTrue(error is NotesWriteError, "\(error)")
            }
        }
        XCTAssertTrue(runner.recorded.isEmpty)
    }
}
