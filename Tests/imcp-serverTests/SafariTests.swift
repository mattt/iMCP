import AppKit
import Foundation
import MCP
import XCTest
import os

/// These tests read fixture text and send no Apple events to Safari.
final class SafariTests: XCTestCase {
    /// A file in the shape that Safari's File > Export > Bookmarks writes.
    private let export = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <Title>Bookmarks</Title>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 FOLDED ADD_DATE="1700000000">Favorites</H3>
            <DL><p>
                <DT><A HREF="https://swift.org/" ADD_DATE="1700000100">Swift.org</A>
                <DT><H3 ADD_DATE="1700000200">News</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/a?x=1&amp;y=2" ADD_DATE="1710000000">Tom &amp; Jerry&#39;s &#x41;</A>
                </DL><p>
            </DL><p>
            <DT><H3>Favorites 2</H3>
            <DL><p>
                <dt><a href='https://apple.com/' add_date=1720000000>Apple</a>
            </DL><p>
            <DT><A HREF="https://top.example/">Unfiled <b>bold</b> page</A>
            <DT><A ADD_DATE="1">No address</A>
            <DT><A HREF="https://untitled.example/"></A>
        </DL><p>
        </HTML>
        """

    private var snapshot: SafariBookmarksSnapshot {
        SafariBookmarksFile.parse(Data(export.utf8))
    }

    // MARK: - The file

    func testFoldersNestAndLinksKeepTheirFolders() {
        let bookmarks = snapshot.bookmarks
        XCTAssertEqual(
            bookmarks.map(\.title),
            ["Swift.org", "Tom & Jerry's A", "Apple", "Unfiled bold page", "https://untitled.example/"]
        )
        XCTAssertEqual(bookmarks.map(\.folderPath), ["Favorites", "Favorites/News", "Favorites 2", "", ""])
        XCTAssertEqual(snapshot.folderPaths, ["Favorites", "Favorites/News", "Favorites 2"])
    }

    func testAddressesDatesAndOddMarkupAreRead() {
        let bookmarks = snapshot.bookmarks
        XCTAssertEqual(bookmarks[1].url, "https://example.com/a?x=1&y=2")
        XCTAssertEqual(bookmarks[0].addedDate, Date(timeIntervalSince1970: 1_700_000_100))
        // Lowercase tags and bare attribute values.
        XCTAssertEqual(bookmarks[2].url, "https://apple.com/")
        XCTAssertEqual(bookmarks[2].addedDate, Date(timeIntervalSince1970: 1_720_000_000))
        XCTAssertNil(bookmarks[3].addedDate)
    }

    func testAFileWithNoLinksHasNoBookmarks() {
        XCTAssertTrue(SafariBookmarksFile.parse(Data("<html><body>nothing</body></html>".utf8)).bookmarks.isEmpty)
        XCTAssertTrue(SafariBookmarksFile.parse(Data()).bookmarks.isEmpty)
        // A tag that never closes ends the read without a crash.
        XCTAssertTrue(SafariBookmarksFile.parse(Data("<A HREF=\"https://x".utf8)).bookmarks.isEmpty)
    }

    func testEntitiesAreDecodedAndUnknownOnesKept() {
        XCTAssertEqual(SafariBookmarksFile.decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot;"), "a & b <c> \"d\"")
        XCTAssertEqual(SafariBookmarksFile.decodeEntities("&#233;&#xe9;"), "éé")
        XCTAssertEqual(SafariBookmarksFile.decodeEntities("AT&T &bogus; &#xZZ; tail&"), "AT&T &bogus; &#xZZ; tail&")
    }

    // MARK: - Searching

    func testSearchWordsAllMustAppearInTitleAddressOrFolder() {
        func titles(_ text: String) -> [String] {
            SafariBookmarkQuery(text: text).run(on: snapshot).page.map(\.title)
        }
        XCTAssertEqual(titles("swift"), ["Swift.org"])
        XCTAssertEqual(titles("EXAMPLE news"), ["Tom & Jerry's A"])
        XCTAssertEqual(titles("jerry nonexistent"), [])
        XCTAssertEqual(titles("  "), snapshot.bookmarks.map(\.title))
    }

    func testFolderFilterIncludesSubfoldersButNotNeighbours() {
        func titles(_ folder: String) -> [String] {
            SafariBookmarkQuery(folder: folder).run(on: snapshot).page.map(\.title)
        }
        XCTAssertEqual(titles("Favorites"), ["Swift.org", "Tom & Jerry's A"])
        XCTAssertEqual(titles("favorites/news/"), ["Tom & Jerry's A"])
        XCTAssertEqual(titles("Favorites 2"), ["Apple"])
        XCTAssertEqual(titles("Fav"), [])
    }

    func testDateFiltersLeaveOutBookmarksWithoutADate() {
        let query = SafariBookmarkQuery(addedAfter: Date(timeIntervalSince1970: 1_705_000_000))
        XCTAssertEqual(query.run(on: snapshot).page.map(\.title), ["Tom & Jerry's A", "Apple"])
        let range = SafariBookmarkQuery(
            addedAfter: Date(timeIntervalSince1970: 1_700_000_000),
            addedBefore: Date(timeIntervalSince1970: 1_710_000_000)
        )
        XCTAssertEqual(range.run(on: snapshot).page.map(\.title), ["Swift.org"])
    }

    func testPagingReportsTheTotalBeforeTheLimit() {
        var query = SafariBookmarkQuery(limit: 2, offset: 1)
        var result = query.run(on: snapshot)
        XCTAssertEqual(result.total, 5)
        XCTAssertEqual(result.page.map(\.title), ["Tom & Jerry's A", "Apple"])
        query.offset = 9
        result = query.run(on: snapshot)
        XCTAssertEqual(result.total, 5)
        XCTAssertTrue(result.page.isEmpty)
    }

    func testBadPagingIsRefused() {
        XCTAssertThrowsError(try SafariBookmarkQuery(limit: 0).validated())
        XCTAssertThrowsError(try SafariBookmarkQuery(limit: 201).validated())
        XCTAssertThrowsError(try SafariBookmarkQuery(offset: -1).validated())
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try SafariBookmarkQuery(addedAfter: day, addedBefore: day).validated())
        XCTAssertNoThrow(try SafariBookmarkQuery(limit: 200).validated())
    }

    func testDatesReadAsISOOrDateOnly() throws {
        XCTAssertEqual(SafariDates.parse("2026-01-02T03:04:05Z"), Date(timeIntervalSince1970: 1_767_323_045))
        XCTAssertNotNil(SafariDates.parse("2026-01-02T03:04:05.250Z"))
        XCTAssertEqual(
            SafariDates.parse("2026-01-02"),
            Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2))
        )
        XCTAssertNil(SafariDates.parse("yesterday"))
    }

    // MARK: - Reading List

    private final class FakeRunner: SafariScriptRunning, @unchecked Sendable {
        let isRunning: Bool
        let calls = OSAllocatedUnfairLock(initialState: [NSAppleScript.Subroutine]())

        init(isRunning: Bool) { self.isRunning = isRunning }

        func run(calling subroutine: NSAppleScript.Subroutine) async throws {
            guard isRunning else { throw SafariError.notRunning }
            calls.withLock { $0.append(subroutine) }
        }
    }

    func testOnlyWebAddressesAreAccepted() {
        for url in [
            "", "   ", "javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/", "example.com",
            "https://", "http:///path", "https://exa mple.com",
            "https://example.com/" + String(repeating: "a", count: SafariReadingListItem.maximumURLLength),
        ] {
            XCTAssertThrowsError(try SafariReadingListItem(url: url, title: nil, previewText: nil), url)
        }
        XCTAssertNoThrow(
            try SafariReadingListItem(
                url: "HTTPS://Example.com/a b".replacingOccurrences(of: " ", with: "%20"),
                title: nil,
                previewText: nil
            )
        )
    }

    func testTitleAndPreviewHaveLimitsAndAreTrimmed() throws {
        let item = try SafariReadingListItem(url: " https://example.com/ ", title: "  Hello \n", previewText: nil)
        XCTAssertEqual(item.url, "https://example.com/")
        XCTAssertEqual(item.title, "Hello")
        XCTAssertEqual(item.previewText, "")
        XCTAssertThrowsError(
            try SafariReadingListItem(
                url: "https://example.com/",
                title: String(repeating: "t", count: SafariReadingListItem.maximumTitleLength + 1),
                previewText: nil
            )
        )
        XCTAssertThrowsError(
            try SafariReadingListItem(
                url: "https://example.com/",
                title: nil,
                previewText: String(repeating: "p", count: SafariReadingListItem.maximumPreviewLength + 1)
            )
        )
    }

    func testCallerTextReachesTheScriptOnlyAsAnArgument() async throws {
        let hostile = "x\" & (do shell script \"id\") & \""
        let runner = FakeRunner(isRunning: true)
        let result = try await SafariService.addToReadingList(
            ["url": "https://example.com/", "title": .string(hostile), "previewText": .string(hostile)],
            runner: runner
        )
        XCTAssertEqual(result, ["added": true, "url": "https://example.com/"])
        let call = try XCTUnwrap(runner.calls.withLock { $0.first })
        XCTAssertEqual(call.name, "addreadinglistitem")
        XCTAssertEqual(call.parameters, [.string("https://example.com/"), .string(hostile), .string(hostile)])
        XCTAssertFalse(SafariScripts.source.contains("do shell script"))
    }

    func testABadRequestSendsNothingAndASafariThatIsClosedIsNotStarted() async {
        let running = FakeRunner(isRunning: true)
        do {
            _ = try await SafariService.addToReadingList(["url": "javascript:alert(1)"], runner: running)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error is SafariError, "\(error)")
        }
        XCTAssertTrue(running.calls.withLock { $0.isEmpty })

        let closed = FakeRunner(isRunning: false)
        do {
            _ = try await SafariService.addToReadingList(["url": "https://example.com/"], runner: closed)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SafariError, .notRunning)
        }
    }

    func testTheScriptCompilesWhereSafariIsInstalled() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariScripts.bundleID) != nil else {
            throw XCTSkip("Safari isn't installed")
        }
        var errorInfo: NSDictionary?
        let script = try XCTUnwrap(NSAppleScript(source: SafariScripts.source))
        XCTAssertTrue(script.compileAndReturnError(&errorInfo), String(describing: errorInfo))
    }

    func testOnlyAddingToTheReadingListIsAWrite() {
        let tools = SafariService.shared.tools
        XCTAssertEqual(tools.filter(\.isWrite).map(\.name), ["safari_reading_list_add"])
        XCTAssertFalse(SafariService.shared.writesEnabledByDefault)
    }
}
