import Foundation
import MCP
import XCTest
import os

final class NotesOrganizeTests: XCTestCase {
    private let noteID = "x-coredata://ABC/ICNote/p12"

    // MARK: - Fields

    private func noteFields(plain: String = "Plan\nline", locked: Bool = false, attachments: Int = 0) -> [String] {
        [
            noteID, "Plan", "x-coredata://ABC/ICFolder/p3", "Work",
            "2026-11-16T09:30:00", "2026-11-17T10:00:00", plain, "<div><h1>Plan</h1></div><div>line</div>",
            locked ? "true" : "false", "false", String(attachments), "iCloud",
        ]
    }

    func testNoteFieldsAreReadInOrder() throws {
        let note = try NotesScriptNote(fields: noteFields(attachments: 2))
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(note.folder, "Work")
        XCTAssertEqual(note.account, "iCloud")
        XCTAssertEqual(note.attachmentCount, 2)
        XCTAssertFalse(note.isPasswordProtected)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(note.modified))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 11, 17, 10])
        XCTAssertThrowsError(try NotesScriptNote(fields: ["short"]))
    }

    func testContentHashIsStableAndTracksTheText() throws {
        let first = try NotesScriptNote(fields: noteFields(plain: "Plan\nline"))
        let same = try NotesScriptNote(fields: noteFields(plain: "Plan\nline"))
        let edited = try NotesScriptNote(fields: noteFields(plain: "Plan\nline!"))
        XCTAssertEqual(first.contentHash, same.contentHash)
        XCTAssertNotEqual(first.contentHash, edited.contentHash)
        XCTAssertEqual(first.contentHash.count, 64)
        // SHA-256 of "abc".
        XCTAssertEqual(
            NotesContentHash.hash(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testAStaleHashIsRefused() throws {
        let note = try NotesScriptNote(fields: noteFields(plain: "now"))
        XCTAssertNoThrow(try NotesContentHash.requireCurrent(note, expected: note.contentHash.uppercased()))
        XCTAssertThrowsError(try NotesContentHash.requireCurrent(note, expected: NotesContentHash.hash(of: "before"))) {
            XCTAssertEqual($0 as? NotesWriteError, .stale)
        }
        XCTAssertThrowsError(try NotesContentHash.requireCurrent(note, expected: "  "))
    }

    func testSummariesAreSortedAndLeaveOutDeletedNotes() throws {
        let fields = [
            "id1", "Old", "Work", "f1", "2026-01-01T00:00:00",
            "id2", "New", "Work", "f1", "2026-06-01T00:00:00",
            "id3", "Gone", "Recently Deleted", "f2", "2026-12-01T00:00:00",
        ]
        let recent = NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: 5)
        XCTAssertEqual(recent.map(\.id), ["id2", "id1"])
        XCTAssertEqual(
            NotesScriptSummary.recent(try NotesScriptSummary.list(from: fields), limit: 1).map(\.id),
            ["id2"]
        )
        XCTAssertThrowsError(try NotesScriptSummary.list(from: ["a", "b"]))
    }

    func testFoldersFormATree() throws {
        let fields = [
            "a", "Work", "", "iCloud", "2",
            "b", "Clients", "a", "iCloud", "1",
            "c", "Stray", "missing", "iCloud", "0",
        ]
        let tree = NotesScriptFolder.tree(try NotesScriptFolder.list(from: fields))
        XCTAssertEqual(tree.map(\.folder.name), ["Work", "Stray"])
        XCTAssertEqual(tree[0].children.map(\.folder.name), ["Clients"])
        XCTAssertEqual(tree[0].folder.noteCount, 2)
    }

    // MARK: - Input

    func testNoteIDsMustBeCoreDataIDs() throws {
        XCTAssertEqual(try NotesOrganizeInput.validatedNoteID(" \(noteID) "), noteID)
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteID("12"))
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteID("x-coredata://a\nb"))
        XCTAssertThrowsError(try NotesOrganizeInput.validatedNoteIDs([]))
        XCTAssertThrowsError(
            try NotesOrganizeInput.validatedNoteIDs(
                Array(repeating: noteID, count: NotesOrganizeInput.maximumBatch + 1)
            )
        )
        XCTAssertThrowsError(try NotesOrganizeInput.validatedPath("relative/file", called: "path"))
        XCTAssertEqual(try NotesOrganizeInput.validatedPath("/tmp/a.png", called: "path"), "/tmp/a.png")
        XCTAssertThrowsError(try NotesOrganizeInput.validatedLimit(0, default: 20))
    }

    func testStagedFilenamesCantLeaveTheirFolder() throws {
        XCTAssertEqual(try NotesAttachmentStaging.safeFilename(" a.png "), "a.png")
        for bad in ["", "..", "a/b", "../x", "a\nb"] {
            XCTAssertThrowsError(try NotesAttachmentStaging.safeFilename(bad), bad)
        }
        let file = try NotesAttachmentStaging.stage(base64: Data("hello".utf8).base64EncodedString(), filename: "n.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        XCTAssertThrowsError(try NotesAttachmentStaging.stage(base64: "!!!", filename: "n.txt"))
    }

    // MARK: - Scripts

    func testCallsPassEveryValueAsAParameter() throws {
        let text = #"" & (do shell script "id") & ""#
        let update = NotesOrganizeScripts.updateNote(id: noteID, expectedPlainText: text, bodyHTML: text)
        XCTAssertEqual(update.parameters, [.string(noteID), .string(text), .string(text)])
        let path = try NotesFolderPath.parse("A/\(text)")
        XCTAssertEqual(
            NotesOrganizeScripts.deleteFolder(account: text, folder: path, deleteContents: true).parameters,
            [.string(text), .strings(["A", text]), .boolean(true)]
        )
        let append = NotesOrganizeScripts.appendToNote(id: noteID, expectedPlainText: nil, additionHTML: "x")
        XCTAssertEqual(append.parameters[2], .boolean(false))
        XCTAssertFalse(NotesOrganizeScripts.organizeSource.contains("do shell script"))
    }

    func testEveryHandlerTheToolsCallIsInTheScript() {
        let calls = [
            NotesOrganizeScripts.getNote("x"), NotesOrganizeScripts.selectedNotes, NotesOrganizeScripts.defaultLocation,
            NotesOrganizeScripts.listFolders(account: nil), NotesOrganizeScripts.deleteNote("x"),
            NotesOrganizeScripts.showNote("x"), NotesOrganizeScripts.listAttachments("x"),
            NotesOrganizeScripts.addAttachment(id: "x", path: "/a"),
            NotesOrganizeScripts.saveAttachment(id: "x", attachmentID: "y", path: "/a"),
            NotesOrganizeScripts.updateNote(id: "x", expectedPlainText: "", bodyHTML: ""),
            NotesOrganizeScripts.appendToNote(id: "x", expectedPlainText: nil, additionHTML: ""),
            NotesOrganizeScripts.listNotes(account: nil, folder: NotesFolderPath(components: [])),
            NotesOrganizeScripts.moveNote(id: "x", account: nil, folder: NotesFolderPath(components: ["A"])),
            NotesOrganizeScripts.renameFolder(account: nil, folder: NotesFolderPath(components: ["A"]), newName: "B"),
            NotesOrganizeScripts.showFolder(account: nil, folder: NotesFolderPath(components: ["A"])),
        ]
        for call in calls {
            XCTAssertTrue(NotesOrganizeScripts.source.contains("on \(call.name)("), call.name)
        }
    }

    // MARK: - Markdown and exports

    func testNotesHTMLBecomesMarkdown() {
        let html =
            "<div><h1>Plan</h1></div><div>Some <b>bold</b> and <i>italic</i> with <a href=\"https://example.com/a?b=1&amp;c=2\">a link</a> &amp; more</div><div><br></div><div><h2>Steps</h2></div><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li><li>second</li></ol><div><tt>code</tt></div>"
        XCTAssertEqual(
            NotesHTMLToMarkdown.markdown(fromHTML: html),
            """
            # Plan
            Some **bold** and *italic* with [a link](https://example.com/a?b=1&c=2) & more

            ## Steps
            - one
            - two
              - nested
            1. first
            2. second
            `code`
            """
        )
    }

    func testTablesImagesAndEntitiesConvert() {
        let html =
            "<table><tr><td>A</td><td>B|C</td></tr><tr><td>1</td><td>2</td></tr></table><div>caf&#233; &lt;tag&gt;<img src=\"cid:x\"></div><style>p{}</style><!-- hidden --><div>end</div>"
        XCTAssertEqual(
            NotesHTMLToMarkdown.markdown(fromHTML: html),
            """
            | A | B\\|C |
            | --- | --- |
            | 1 | 2 |
            café <tag>[image]
            end
            """
        )
    }

    private func item(_ title: String, locked: Bool = false) throws -> NotesExportItem {
        var fields = noteFields(plain: "\(title)\nbody")
        fields[1] = title
        fields[7] = "<div><h1>\(title)</h1></div><div>body</div>"
        fields[8] = locked ? "true" : "false"
        return NotesExportItem(try NotesScriptNote(fields: fields))
    }

    func testExportsInEveryFormat() throws {
        let items = [try item("One"), try item("Two \"quoted\""), try item("Locked", locked: true)]

        let json = try NotesExporter.export(items, as: .json)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[1]["title"] as? String, "Two \"quoted\"")
        XCTAssertEqual(decoded[0]["plainText"] as? String, "One\nbody")
        XCTAssertEqual(decoded[2]["locked"] as? Bool, true)

        let markdown = try NotesExporter.export(items, as: .markdown)
        XCTAssertTrue(markdown.contains("title: \"Two \\\"quoted\\\"\""))
        XCTAssertTrue(markdown.contains("# One\nbody"))
        XCTAssertTrue(markdown.contains("id: \"x-coredata://ABC/ICNote/p12\""))

        let html = try NotesExporter.export(items, as: .html)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertEqual(html.components(separatedBy: "<article").count - 1, 3)
        XCTAssertTrue(html.contains("This note is locked with a password."))
        XCTAssertFalse(html.contains("<h1>Locked</h1>"))
    }

    // MARK: - Tools

    private final class FakeRunner: NotesScriptRunning {
        private let calls = OSAllocatedUnfairLock(initialState: [NSAppleScript.Subroutine]())
        var recorded: [NSAppleScript.Subroutine] { calls.withLock { $0 } }
        let plain: String
        let failingIDs: Set<String>

        init(plain: String = "Plan\nline", failingIDs: Set<String> = []) {
            self.plain = plain
            self.failingIDs = failingIDs
        }

        func run(_ source: String, calling subroutine: NSAppleScript.Subroutine) async throws -> [String] {
            calls.withLock { $0.append(subroutine) }
            if case .string(let id)? = subroutine.parameters.first, failingIDs.contains(id) {
                throw NotesWriteError.scriptFailed("There is no note with the id: \(id)")
            }
            switch subroutine.name {
            case "getNote":
                return [
                    "x-coredata://ABC/ICNote/p12", "Plan", "f", "Work", "2026-11-16T09:30:00", "2026-11-17T10:00:00",
                    plain, "<div><h1>Plan</h1></div>", "false", "false", "0", "iCloud",
                ]
            case "updateNote", "appendToNote": return ["x-coredata://ABC/ICNote/p12", "Plan", "2026-11-17T11:00:00"]
            case "deleteNote": return ["x-coredata://ABC/ICNote/p12", "Plan"]
            case "moveNote": return ["x-coredata://ABC/ICNote/p13", "Plan", "Archive"]
            default: return []
            }
        }
    }

    private func tools(enabled: Bool = true, runner: FakeRunner = FakeRunner()) -> [String: Tool] {
        Dictionary(
            uniqueKeysWithValues: NotesOrganizeTools.tools(isEnabled: { enabled }, runner: runner).map { ($0.name, $0) }
        )
    }

    func testToolSetsMatchTheirNames() {
        let all = tools()
        XCTAssertEqual(Set(all.keys), NotesOrganizeTools.readToolNames.union(NotesOrganizeTools.writeToolNames))
        for name in NotesOrganizeTools.readToolNames {
            XCTAssertEqual(all[name]?.annotations.readOnlyHint, true, name)
        }
        for name in NotesOrganizeTools.writeToolNames {
            XCTAssertEqual(all[name]?.annotations.readOnlyHint, false, name)
        }
        XCTAssertTrue(NotesOrganizeTools.readToolNames.isDisjoint(with: NotesOrganizeTools.writeToolNames))
    }

    func testEveryWriteToolRefusesWhileChangesAreOff() async {
        let runner = FakeRunner()
        let all = tools(enabled: false, runner: runner)
        let arguments: [String: Value] = [
            "id": .string(noteID), "ids": [.string(noteID)], "folder": "A", "newName": "B", "body": "x", "text": "x",
            "expectedContentHash": "h", "path": "/tmp/a", "attachmentId": "a",
        ]
        for name in NotesOrganizeTools.writeToolNames {
            do {
                _ = try await all[name]!(arguments)
                XCTFail("\(name) ran")
            } catch {
                XCTAssertEqual(error as? NotesWriteError, .writesDisabled, name)
            }
        }
        XCTAssertTrue(runner.recorded.isEmpty)
    }

    func testUpdateWritesOnlyWhenTheHashIsCurrent() async throws {
        let runner = FakeRunner(plain: "Plan\nline")
        let all = tools(runner: runner)
        let hash = NotesContentHash.hash(of: "Plan\nline")

        _ = try await all["notes_update"]!([
            "id": .string(noteID), "expectedContentHash": .string(hash), "body": "new <body>",
        ])
        let update = try XCTUnwrap(runner.recorded.last)
        XCTAssertEqual(update.name, "updateNote")
        XCTAssertEqual(update.parameters[1], .string("Plan\nline"))
        XCTAssertEqual(
            update.parameters[2],
            .string("<div><h1>Plan</h1></div><div>new &lt;body&gt;</div>")
        )

        let before = runner.recorded.count
        do {
            _ = try await all["notes_update"]!([
                "id": .string(noteID), "expectedContentHash": .string(NotesContentHash.hash(of: "older")), "body": "x",
            ])
            XCTFail("a stale update ran")
        } catch {
            XCTAssertEqual(error as? NotesWriteError, .stale)
        }
        // Only the read happened.
        XCTAssertEqual(runner.recorded.count, before + 1)
        XCTAssertEqual(runner.recorded.last?.name, "getNote")
    }

    func testBatchesReportEachNote() async throws {
        let bad = "x-coredata://ABC/ICNote/p99"
        let runner = FakeRunner(failingIDs: [bad])
        let all = tools(runner: runner)
        let result = try await all["notes_batch_move"]!([
            "ids": [.string(noteID), .string(bad)], "folder": "Archive",
        ])
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["succeeded"]?.intValue, 1)
        XCTAssertEqual(object["failed"]?.intValue, 1)
        let rows = try XCTUnwrap(object["results"]?.arrayValue)
        XCTAssertEqual(rows[0].objectValue?["newId"]?.stringValue, "x-coredata://ABC/ICNote/p13")
        XCTAssertEqual(rows[1].objectValue?["ok"]?.boolValue, false)
    }
}
