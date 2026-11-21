import Foundation
import TopoText
import XCTest

final class NotesTests: XCTestCase {
    private typealias Attachment = TopoText.Note.Attachment
    private typealias Content = TopoText.Note.Content
    private typealias Paragraph = TopoText.Note.Paragraph
    private typealias Run = TopoText.Note.TextRun

    private func attachment(_ id: String, type: String, text: String? = nil, url: String? = nil) -> Run {
        Run(
            text: "\u{FFFC}",
            attachment: Attachment(
                id: Attachment.ID(id)!,
                typeIdentifier: type,
                displayText: text,
                title: "Title \(id)",
                url: url.flatMap(URL.init(string:)),
                fileName: type == "public.jpeg" ? "\(id).jpg" : nil
            )
        )
    }

    private var sample: Content {
        let linked = Run(text: "docs", link: "https://example.com/docs")
        return Content(paragraphs: [
            Paragraph(style: .init(kind: .title), runs: [Run(text: "Trip plan")]),
            Paragraph(
                runs: [
                    Run(text: "Book "),
                    attachment("T1", type: "com.apple.notes.inlinetextattachment.hashtag", text: "#Travel"),
                    Run(text: " and "),
                    attachment("T2", type: "com.apple.notes.inlinetextattachment.hashtag", text: "#travel"),
                    Run(text: " "),
                    linked,
                ]
            ),
            Paragraph(style: .init(kind: .checklist), runs: [Run(text: "Passport")]),
            Paragraph(runs: [attachment("I1", type: "public.jpeg")]),
            Paragraph(runs: [attachment("TB", type: "com.apple.notes.table")]),
            Paragraph(runs: [attachment("W1", type: "public.url", url: "https://example.org/a")]),
        ])
    }

    func testTraitsReadTagsFeaturesWordsAndLinks() {
        let traits = NoteTraits(content: sample)
        // The tag appears twice with different case, and counts once.
        XCTAssertEqual(traits.tags, ["#Travel"])
        XCTAssertEqual(traits.features, [.attachment, .checklist, .table, .link, .image])
        XCTAssertEqual(traits.links, ["https://example.com/docs", "https://example.org/a"])
        // "Trip plan", "Book  and  docs" (tags are not words), "Passport".
        XCTAssertEqual(traits.wordCount, 2 + 3 + 1)
    }

    func testFilterAppliesEveryCondition() {
        let traits = NoteTraits(content: sample)
        // Tags come from the database's tag records, the same ones `keywords` uses.
        let tags = [TopoText.Note.Tag("#Travel")!]
        XCTAssertTrue(
            NoteFilter(tags: ["#travel"], features: [.table, .checklist]).matches(tags: tags)
        )
        XCTAssertTrue(NoteFilter(tags: ["#travel"]).matches(tags: tags))
        XCTAssertFalse(NoteFilter(tags: ["travel", "work"]).matches(tags: tags))
        XCTAssertFalse(NoteFilter(features: [.drawing]).matches(traits))
        XCTAssertTrue(NoteFilter(minimumWords: 6, maximumWords: 6).matches(traits))
        XCTAssertFalse(NoteFilter(minimumWords: 7).matches(traits))
        XCTAssertFalse(NoteFilter(maximumWords: 5).matches(traits))
        XCTAssertTrue(NoteFilter().isEmpty)
        XCTAssertFalse(NoteFilter(isPinned: true).needsContents)
        // A tag filter reads tag records, not the note's text.
        XCTAssertTrue(NoteFilter(tags: ["a"]).needsTags)
        XCTAssertFalse(NoteFilter(tags: ["a"]).needsContents)
    }

    func testFilterMatchesFlagsAndCreationRange() {
        let day = Date(timeIntervalSinceReferenceDate: 100_000)
        let filter = NoteFilter(isPinned: true, createdStart: day, createdEnd: day.addingTimeInterval(60))
        XCTAssertTrue(filter.matches(isPinned: true, isLocked: false, creationDate: day))
        XCTAssertFalse(filter.matches(isPinned: false, isLocked: false, creationDate: day))
        // The end of the range is exclusive, and a note without a date can't be in a range.
        XCTAssertFalse(filter.matches(isPinned: true, isLocked: false, creationDate: day.addingTimeInterval(60)))
        XCTAssertFalse(filter.matches(isPinned: true, isLocked: false, creationDate: nil))
        XCTAssertFalse(NoteFilter(isLocked: false).matches(isPinned: false, isLocked: true, creationDate: nil))
    }

    func testNormalizedTag() {
        XCTAssertEqual(NoteFilter.normalizedTag(" ##Groceries "), "Groceries")
        XCTAssertNil(NoteFilter.normalizedTag("#"))
    }

    func testAttachmentValuesLeaveOutInlineTextAndReportSizes() {
        let values = attachmentValues(in: sample) { $0.fileName == nil ? nil : 2_048 }
        XCTAssertEqual(values.count, 3)
        let image = values.compactMap(\.objectValue).first { $0["kind"] == "image" }
        XCTAssertEqual(image?["name"], "I1.jpg")
        XCTAssertEqual(image?["encodingFormat"], "public.jpeg")
        XCTAssertEqual(image?["contentSize"], .int(2_048))
        let web = values.compactMap(\.objectValue).first { $0["kind"] == "webLink" }
        XCTAssertEqual(web?["url"], "https://example.org/a")
        XCTAssertNil(web?["contentSize"])
    }

    func testFolderPathStopsAtUnknownParentsAndLoops() {
        let a = TopoText.Folder.ID("A")!
        let b = TopoText.Folder.ID("B")!
        let c = TopoText.Folder.ID("C")!
        let nodes = [
            FolderNode(id: a, name: "Work", parentID: nil),
            FolderNode(id: b, name: "Plans", parentID: a),
            FolderNode(id: c, name: "Orphan", parentID: TopoText.Folder.ID("missing")!),
        ]
        XCTAssertEqual(folderPath(of: b, in: nodes), "Work/Plans")
        XCTAssertEqual(folderPath(of: c, in: nodes), "Orphan")
        XCTAssertNil(folderPath(of: TopoText.Folder.ID("Z")!, in: nodes))
        let loop = [FolderNode(id: a, name: "A", parentID: b), FolderNode(id: b, name: "B", parentID: a)]
        XCTAssertEqual(folderPath(of: a, in: loop), "B/A")
    }

    func testStatisticsCountRecentlyDeletedApart() {
        var statistics = NoteStatistics()
        let early = Date(timeIntervalSinceReferenceDate: 1_000)
        let late = Date(timeIntervalSinceReferenceDate: 9_000)
        statistics.add(
            isPinned: true,
            isLocked: false,
            isRecentlyDeleted: false,
            account: "iCloud",
            modificationDate: late
        )
        statistics.add(
            isPinned: false,
            isLocked: true,
            isRecentlyDeleted: false,
            account: "iCloud",
            modificationDate: early
        )
        statistics.add(
            isPinned: true,
            isLocked: false,
            isRecentlyDeleted: true,
            account: "iCloud",
            modificationDate: nil
        )
        let object = statistics.value.objectValue
        XCTAssertEqual(object?["numberOfItems"], .int(2))
        XCTAssertEqual(object?["numberOfPinnedItems"], .int(1))
        XCTAssertEqual(object?["numberOfLockedItems"], .int(1))
        XCTAssertEqual(object?["numberOfRecentlyDeletedItems"], .int(1))
        XCTAssertEqual(object?["numberOfItemsByAccount"]?.objectValue?["iCloud"], .int(2))
        XCTAssertEqual(object?["oldestDateModified"], .string(early.formatted(.iso8601)))
        XCTAssertNil(object?["description"])
    }

    func testNoteURLUsesTheIdentifier() {
        XCTAssertEqual(
            noteURL(for: TopoText.Note.ID("ABC-123")!),
            "notes://showNote?identifier=ABC-123"
        )
    }

    // MARK: - Search

    private struct FakeNote: FilterableNote {
        var id: TopoText.Note.ID
        var isPinned = false
        var isLocked = false
        var creationDate: Date?
    }

    /// Notes numbered 0..<count, newest first. Every `matchEvery`th note matches the text query.
    private final class FakeSource: NoteSearchSource {
        let count: Int
        let matchEvery: Int
        var unreadable: Set<Int> = []
        var tagsAvailable = true
        var requests: [TopoText.Note.FetchRequest] = []
        var scanned = 0

        init(count: Int, matchEvery: Int) {
            self.count = count
            self.matchEvery = matchEvery
        }

        private func position(of cursor: TopoText.Note.FetchRequest.Cursor?) -> Int {
            guard let cursor else { return 0 }
            return Int(cursor.description.split(separator: ":")[2])!
        }

        func search(_ request: TopoText.Note.FetchRequest) throws -> SearchPage<FakeNote> {
            requests.append(request)
            var index = position(of: request.cursor)
            var notes: [FakeNote] = []
            var ids: [TopoText.Note.ID] = []
            var examined = 0
            while index < count, examined < request.scanLimit, notes.count < request.limit {
                examined += 1
                if unreadable.contains(index) { ids.append(.init("N\(index)")!) }
                if index % matchEvery == 0 || unreadable.contains(index) {
                    notes.append(FakeNote(id: .init("N\(index)")!))
                }
                index += 1
            }
            scanned += examined
            return SearchPage(
                notes: notes,
                nextCursor: index < count ? .init("s:1:\(index)") : nil,
                scannedNoteCount: examined,
                unreadableNoteIDs: ids
            )
        }

        func tags(for ids: [TopoText.Note.ID]) throws -> [TopoText.Note.ID: [TopoText.Note.Tag]]? {
            tagsAvailable ? [:] : nil
        }

        func content(for id: TopoText.Note.ID) throws -> TopoText.Note.Content {
            throw NotesError.noteNotFound(id)
        }
    }

    func testSearchNeverScansPastTheBudgetWithASparseFilter() throws {
        // Matches are sparse and the filter rejects them all, so the search keeps asking for more.
        let source = FakeSource(count: 20_000, matchEvery: 300)
        let request = TopoText.Note.FetchRequest(query: "x", limit: 30)
        let page = try searchNotes(
            request,
            filter: NoteFilter(isPinned: true),
            scanLimit: 2_500,
            contentReadLimit: 500,
            in: source
        )
        XCTAssertLessThanOrEqual(source.scanned, 2_500)
        XCTAssertEqual(page.stoppedEarly, .metadataScan)
        XCTAssertNotNil(page.nextCursor)
    }

    func testSearchKeepsUnreadableNotesOnceWhetherOrNotTheyMatch() throws {
        let source = FakeSource(count: 10, matchEvery: 1_000)
        source.unreadable = [3]
        let page = try searchNotes(
            TopoText.Note.FetchRequest(query: "x", limit: 10),
            filter: NoteFilter(),
            scanLimit: 100,
            contentReadLimit: 500,
            in: source
        )
        XCTAssertEqual(page.unreadableNoteIDs.map(\.description), ["N3"])
        XCTAssertEqual(page.notes.map(\.id.description), ["N0", "N3"])
    }

    func testSearchReportsAnUnreadableNoteOnceWhenItsContentsAreNeeded() throws {
        let source = FakeSource(count: 10, matchEvery: 1_000)
        source.unreadable = [3]
        // The filter needs contents, and the fake can't supply them.
        let page = try searchNotes(
            TopoText.Note.FetchRequest(query: "x", limit: 10),
            filter: NoteFilter(minimumWords: 1),
            scanLimit: 100,
            contentReadLimit: 500,
            in: source
        )
        XCTAssertEqual(page.unreadableNoteIDs.map(\.description), ["N3", "N0"])
        XCTAssertTrue(page.notes.isEmpty)
    }

    func testSearchCarriesTheCursorOfThePage() throws {
        let source = FakeSource(count: 100, matchEvery: 1)
        let page = try searchNotes(
            TopoText.Note.FetchRequest(limit: 5),
            filter: NoteFilter(),
            scanLimit: 2_000,
            contentReadLimit: 500,
            in: source
        )
        XCTAssertEqual(page.notes.count, 5)
        XCTAssertEqual(page.nextCursor?.description, "s:1.0:5")
        let next = try searchNotes(
            TopoText.Note.FetchRequest(limit: 5, cursor: page.nextCursor),
            filter: NoteFilter(),
            scanLimit: 2_000,
            contentReadLimit: 500,
            in: source
        )
        XCTAssertEqual(next.notes.first?.id.description, "N5")
    }

    func testTagFilterFailsWhenTagRecordsCannotBeRead() {
        let source = FakeSource(count: 10, matchEvery: 1)
        source.tagsAvailable = false
        XCTAssertThrowsError(
            try searchNotes(
                TopoText.Note.FetchRequest(limit: 5),
                filter: NoteFilter(tags: ["a"]),
                scanLimit: 100,
                contentReadLimit: 500,
                in: source
            )
        ) { XCTAssertTrue($0 is NoteTagsUnavailableError) }
    }

    func testFindsTheFolderAndNoteAScriptCreated() {
        let a = TopoText.Folder.ID("A")!
        let b = TopoText.Folder.ID("B")!
        let c = TopoText.Folder.ID("C")!
        let nodes = [
            FolderNode(id: a, name: "Work", parentID: nil, accountName: "iCloud"),
            FolderNode(id: b, name: "Ideas", parentID: a, accountName: "iCloud"),
            FolderNode(id: c, name: "Ideas", parentID: nil, accountName: "On My Mac"),
        ]
        XCTAssertEqual(
            folderIDs(atPath: ["Work", "Ideas"], defaultFolderName: "", accountName: "iCloud", among: nodes),
            [b]
        )
        XCTAssertEqual(folderIDs(atPath: [], defaultFolderName: "Ideas", accountName: "On My Mac", among: nodes), [c])

        let now = Date()
        let one = NoteCandidate(id: .init("1")!, title: "Plan", creationDate: now)
        let old = NoteCandidate(id: .init("2")!, title: "Plan", creationDate: now.addingTimeInterval(-3_600))
        let other = NoteCandidate(id: .init("3")!, title: "Plan B", creationDate: now)
        XCTAssertEqual(
            uniqueNewNoteID(title: "Plan", createdAfter: now.addingTimeInterval(-60), among: [one, old, other]),
            .init("1")!
        )
        // Two new notes with the title: no guess.
        let twin = NoteCandidate(id: .init("4")!, title: "Plan", creationDate: now)
        XCTAssertNil(uniqueNewNoteID(title: "Plan", createdAfter: now.addingTimeInterval(-60), among: [one, twin]))
        XCTAssertNil(uniqueNewNoteID(title: "Plan", createdAfter: now.addingTimeInterval(-60), among: [old]))
    }
}
