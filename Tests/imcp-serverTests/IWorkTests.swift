import AppKit
import Foundation
import MCP
import XCTest
import os

/// These tests send no Apple events to Pages, Numbers, or Keynote.
/// A fake runner stands in for them, and the compile test only reads the apps' dictionaries.
final class IWorkTests: XCTestCase {
    // MARK: - Cells

    func testCellNamesRoundTripThroughTheirNumbers() throws {
        XCTAssertEqual(try IWorkCellAddress.parse("A1"), IWorkCellAddress(row: 1, column: 1))
        XCTAssertEqual(try IWorkCellAddress.parse(" aa3 "), IWorkCellAddress(row: 3, column: 27))
        XCTAssertEqual(IWorkCellAddress.name(row: 3, column: 27), "AA3")
        XCTAssertEqual(IWorkCellAddress.name(row: 12, column: 26), "Z12")
        XCTAssertEqual(IWorkCellAddress.name(row: 1, column: 703), "AAA1")
    }

    func testMalformedCellsAreRefused() {
        for text in ["", "A", "1", "1A", "A0", "A-1", "AAAA1", "A1B", "A 1", "É1", "A1:B2", "A99999999"] {
            XCTAssertThrowsError(try IWorkCellAddress.parse(text), text)
        }
    }

    func testRangesReadAsCornersAndCountTheirCells() throws {
        let range = try IWorkCellRange.parse("B2:D5")
        XCTAssertEqual(range, IWorkCellRange(firstRow: 2, firstColumn: 2, lastRow: 5, lastColumn: 4))
        XCTAssertEqual(range.cellCount, 12)
        XCTAssertEqual(range.text, "B2:D5")
        XCTAssertEqual(try IWorkCellRange.parse("c7").text, "C7:C7")
    }

    func testBadRangesAreRefused() {
        XCTAssertThrowsError(try IWorkCellRange.parse("D5:B2"))
        XCTAssertThrowsError(try IWorkCellRange.parse("A1:B2:C3"))
        XCTAssertThrowsError(try IWorkCellRange.parse("A1:"))
        XCTAssertThrowsError(try IWorkCellRange.parse("A1:A1001")) { error in
            XCTAssertTrue(error.localizedDescription.contains("1000"), error.localizedDescription)
        }
        XCTAssertNoThrow(try IWorkCellRange.parse("A1:A1000"))
    }

    func testTheLeadingRangeStaysWithinTheLimitAndTheTable() throws {
        XCTAssertNil(IWorkCellRange.leading(rows: 0, columns: 5))
        XCTAssertEqual(IWorkCellRange.leading(rows: 3, columns: 2)?.text, "A1:B3")
        let wide = try XCTUnwrap(IWorkCellRange.leading(rows: 5_000, columns: 200))
        XCTAssertEqual(wide.columnCount, 26)
        XCTAssertLessThanOrEqual(wide.cellCount, IWorkCellRange.maximumCells)
        XCTAssertTrue(wide.fits(rows: 5_000, columns: 200))
        XCTAssertFalse(try IWorkCellRange.parse("A1:C9").fits(rows: 8, columns: 3))
    }

    // MARK: - Input

    func testCellValuesKeepTheirType() throws {
        XCTAssertEqual(try IWorkInput.cellValue(from: .string("=1+1")), .string("=1+1"))
        XCTAssertEqual(try IWorkInput.cellValue(from: .int(4)), .number(4))
        XCTAssertEqual(try IWorkInput.cellValue(from: .double(2.5)), .number(2.5))
        XCTAssertEqual(try IWorkInput.cellValue(from: .bool(true)), .boolean(true))
        XCTAssertThrowsError(try IWorkInput.cellValue(from: .double(.nan)))
        XCTAssertThrowsError(try IWorkInput.cellValue(from: .array([])))
        XCTAssertThrowsError(try IWorkInput.cellValue(from: .null))
        XCTAssertThrowsError(
            try IWorkInput.cellValue(from: .string(String(repeating: "x", count: IWorkInput.maximumCellTextLength + 1)))
        )
    }

    func testNamesAndTextHaveLimits() throws {
        XCTAssertThrowsError(try IWorkInput.validatedName("", called: "document"))
        XCTAssertThrowsError(
            try IWorkInput.validatedName(String(repeating: "a", count: 501), called: "document")
        )
        XCTAssertEqual(try IWorkInput.validatedName(" Q3 plan ", called: "document"), " Q3 plan ")
        XCTAssertThrowsError(try IWorkInput.validatedText("", called: "text", limit: 10))
        XCTAssertThrowsError(try IWorkInput.validatedText("12345678901", called: "text", limit: 10))
    }

    // MARK: - Scripts

    /// A document name that tries to end its string and run a command stays an argument.
    func testCallerTextReachesTheScriptOnlyAsAnArgument() throws {
        let hostile = "x\" & (do shell script \"id\") & \"\n\\"
        let call = IWorkScripts.appendPages(document: hostile, text: hostile)
        XCTAssertEqual(call.parameters, [.string(hostile), .string(hostile)])
        XCTAssertFalse(IWorkScripts.source(for: .pages).contains("do shell script"))

        let event = call.event()
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(arguments.numberOfItems, 2)
        XCTAssertEqual(arguments.atIndex(1)?.stringValue, hostile)
        XCTAssertEqual(arguments.atIndex(2)?.stringValue, hostile)
    }

    func testEachAppsScriptCompilesWhereTheAppIsInstalled() throws {
        for app in IWorkApp.allCases {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil else {
                continue
            }
            var errorInfo: NSDictionary?
            let script = try XCTUnwrap(NSAppleScript(source: IWorkScripts.source(for: app)))
            XCTAssertTrue(script.compileAndReturnError(&errorInfo), "\(app): \(String(describing: errorInfo))")
        }
    }

    // MARK: - Results

    func testResultsConvertToValues() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "text"), at: 1)
        list.insert(NSAppleEventDescriptor(int32: 7), at: 2)
        list.insert(NSAppleEventDescriptor(double: 1.5), at: 3)
        list.insert(NSAppleEventDescriptor(boolean: true), at: 4)
        list.insert(NSAppleEventDescriptor.null(), at: 5)
        XCTAssertEqual(
            IWorkResult.value(from: list),
            .array([.string("text"), .int(7), .double(1.5), .bool(true), .null])
        )
        XCTAssertEqual(IWorkResult.value(from: .list()), .array([]))
    }

    func testLongTextIsCutAndSaysSo() {
        XCTAssertEqual(IWorkResult.truncated("abc", to: 3).wasTruncated, false)
        let cut = IWorkResult.truncated("abcdef", to: 4)
        XCTAssertEqual(cut.text, "abcd")
        XCTAssertTrue(cut.wasTruncated)
    }

    // MARK: - Tools

    private final class FakeRunner: IWorkScriptRunning, @unchecked Sendable {
        let running: Set<IWorkApp>
        let answers: [String: NSAppleEventDescriptor]
        let calls = OSAllocatedUnfairLock(initialState: [String]())

        init(running: Set<IWorkApp>, answers: [String: NSAppleEventDescriptor] = [:]) {
            self.running = running
            self.answers = answers
        }

        func isRunning(_ app: IWorkApp) -> Bool { running.contains(app) }

        func run(_ app: IWorkApp, calling subroutine: NSAppleScript.Subroutine) async throws -> NSAppleEventDescriptor {
            guard running.contains(app) else { throw IWorkError.notRunning(app) }
            calls.withLock { $0.append(subroutine.name) }
            return answers[subroutine.name] ?? .null()
        }
    }

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    private func text(_ string: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: string) }

    /// One sheet, "Budget", with a 4 row by 3 column table "Items".
    private var numbersStructure: NSAppleEventDescriptor {
        list([
            list([
                text("Budget"),
                list([list([text("Items"), NSAppleEventDescriptor(int32: 4), NSAppleEventDescriptor(int32: 3)])]),
            ])
        ])
    }

    private func tool(_ name: String, runner: FakeRunner) throws -> Tool {
        try XCTUnwrap(IWorkTools.tools(runner: runner).first { $0.name == name })
    }

    func testListingSkipsAppsThatAreNotOpenAndStartsNone() async throws {
        let runner = FakeRunner(
            running: [.pages],
            answers: ["listdocuments": list([list([text("Letter"), NSAppleEventDescriptor(boolean: true)])])]
        )
        let result = try await tool("iwork_documents", runner: runner)([:])
        XCTAssertEqual(
            result,
            [
                "documents": .array([["app": "pages", "name": "Letter", "hasUnsavedChanges": true]]),
                "notRunning": .array(["numbers", "keynote"]),
            ]
        )
        XCTAssertEqual(runner.calls.withLock { $0 }, ["listdocuments"])
    }

    func testNumbersWithoutATableListsTheStructure() async throws {
        let runner = FakeRunner(running: [.numbers], answers: ["describenumbers": numbersStructure])
        let result = try await tool("iwork_read_document", runner: runner)(["app": "numbers", "document": "Budget"])
        XCTAssertEqual(
            result.objectValue?["sheets"],
            .array([["name": "Budget", "tables": .array([["name": "Items", "rows": 4, "columns": 3]])]])
        )
        XCTAssertEqual(runner.calls.withLock { $0 }, ["describenumbers"])
    }

    func testNumbersReadsTheLeadingRangeOfTheNamedTable() async throws {
        let rows = list([
            list([text("a"), NSAppleEventDescriptor(int32: 1), .null()])
        ])
        let runner = FakeRunner(
            running: [.numbers],
            answers: ["describenumbers": numbersStructure, "readnumbers": rows]
        )
        let result = try await tool("iwork_read_document", runner: runner)(
            ["app": "numbers", "document": "Budget", "table": "Items"]
        )
        XCTAssertEqual(result.objectValue?["range"], "A1:C4")
        XCTAssertEqual(result.objectValue?["values"], .array([.array(["a", 1, .null])]))
    }

    func testARangeOutsideTheTableSendsNoRead() async throws {
        let runner = FakeRunner(running: [.numbers], answers: ["describenumbers": numbersStructure])
        do {
            _ = try await tool("iwork_read_document", runner: runner)(
                ["app": "numbers", "document": "Budget", "table": "Items", "range": "A1:C5"]
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("outside the table"), "\(error)")
        }
        XCTAssertEqual(runner.calls.withLock { $0 }, ["describenumbers"])
    }

    func testACellOutsideTheTableIsNotSet() async throws {
        let runner = FakeRunner(running: [.numbers], answers: ["describenumbers": numbersStructure])
        do {
            _ = try await tool("iwork_numbers_set_cell", runner: runner)(
                ["document": "Budget", "cell": "D1", "value": 1]
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("outside the table"), "\(error)")
        }
        XCTAssertFalse(runner.calls.withLock { $0 }.contains("setnumberscell"))

        _ = try await tool("iwork_numbers_set_cell", runner: runner)(
            ["document": "Budget", "cell": "c4", "value": "=SUM(A1:A3)"]
        )
        XCTAssertEqual(runner.calls.withLock { $0 }.last, "setnumberscell")
    }

    func testAnAppThatIsNotOpenIsNeverStartedByAWrite() async throws {
        let runner = FakeRunner(running: [])
        do {
            _ = try await tool("iwork_pages_append_text", runner: runner)(["document": "Letter", "text": "More"])
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? IWorkError, .notRunning(.pages))
        }
        XCTAssertTrue(runner.calls.withLock { $0 }.isEmpty)
    }

    func testOnlyTheReadToolsClaimToBeReadOnly() {
        let tools = IWorkTools.tools(runner: FakeRunner(running: []))
        XCTAssertEqual(
            Set(tools.filter { !$0.isWrite }.map(\.name)),
            ["iwork_documents", "iwork_read_document"]
        )
        XCTAssertEqual(tools.count, 5)
        XCTAssertFalse(IWorkService.shared.writesEnabledByDefault)
    }
}
