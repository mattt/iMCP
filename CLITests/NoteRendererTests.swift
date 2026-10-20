import TopoText
import XCTest

final class NoteRendererTests: XCTestCase {
    // MARK: - Escaping

    func testEscapesInlineMarkdownCharacters() {
        XCTAssertEqual(
            markdown([paragraph("Use *stars*, _underscores_, `code`, [brackets], <tags>, and a~b")]),
            #"Use \*stars\*, \_underscores\_, \`code\`, \[brackets\], \<tags\>, and a\~b"#
        )
    }

    func testEscapesMarkersAtLineStart() {
        let lines = [
            "# Groceries", "###### Six", "+ milk", "- eggs", "1. bread", "2) butter", "2024. was a year",
            "---", "===", "  # indented",
        ]
        XCTAssertEqual(
            markdown(lines.map { paragraph($0) }),
            [
                ##"\# Groceries"##, "\\###### Six", #"\+ milk"#, #"\- eggs"#, #"1\. bread"#, #"2\) butter"#,
                #"2024\. was a year"#, #"\---"#, #"\==="#, ##"  \# indented"##,
            ].joined(separator: "\n")
        )
    }

    func testLeavesTextThatOnlyResemblesMarkers() {
        let lines = ["#hashtag", "####### seven", "-5 degrees", "1.5 cups", "1234567890. too long", "--- and more"]
        XCTAssertEqual(markdown(lines.map { paragraph($0) }), lines.joined(separator: "\n"))
    }

    func testEscapesLineStartAfterLineSeparator() {
        XCTAssertEqual(
            markdown([paragraph("Intro\u{2028}# not a heading\u{2028}- not an item")]),
            "Intro\n\\# not a heading\n\\- not an item"
        )
    }

    // MARK: - Inline formatting

    func testFormatsRunsAndKeepsSpacesOutsideMarkers() {
        let content = [
            Note.Paragraph(runs: [
                Note.TextRun(text: "Plain "),
                Note.TextRun(text: "bold ", isBold: true),
                Note.TextRun(text: "italic", isItalic: true),
                Note.TextRun(text: " "),
                Note.TextRun(text: "both", isBold: true, isItalic: true),
                Note.TextRun(text: " "),
                Note.TextRun(text: "gone", isStrikethrough: true),
                Note.TextRun(text: " "),
                Note.TextRun(text: "under", isUnderlined: true),
                Note.TextRun(text: " "),
                Note.TextRun(text: "site", link: "https://example.com"),
            ])
        ]
        XCTAssertEqual(
            markdown(content),
            "Plain **bold** *italic* ***both*** ~~gone~~ under [site](https://example.com)"
        )
    }

    func testMergesNeighboringRunsWithTheSameFormatting() {
        let content = [
            Note.Paragraph(runs: [
                Note.TextRun(text: "Hel", isBold: true),
                Note.TextRun(text: "lo", isBold: true),
            ])
        ]
        XCTAssertEqual(markdown(content), "**Hello**")
    }

    func testEscapesFormattedText() {
        let content = [Note.Paragraph(runs: [Note.TextRun(text: "a*b", isBold: true)])]
        XCTAssertEqual(markdown(content), #"**a\*b**"#)
    }

    // MARK: - Headings and paragraphs

    func testRendersHeadingsWithBlankLinesAround() {
        let content = [
            paragraph("My Note", .title),
            paragraph("Intro"),
            paragraph("Section", .heading),
            paragraph("Part", .subheading),
            paragraph("Body"),
        ]
        XCTAssertEqual(
            markdown(content),
            "# My Note\n\nIntro\n\n## Section\n\n### Part\n\nBody"
        )
    }

    func testJoinsHeadingLinesWithSpaces() {
        XCTAssertEqual(markdown([paragraph("Two\u{2028}lines", .heading)]), "## Two lines")
    }

    func testKeepsEmptyParagraphsAsBlankLines() {
        XCTAssertEqual(markdown([paragraph("a"), Note.Paragraph(), paragraph("b")]), "a\n\nb")
    }

    // MARK: - Lists

    func testNumbersListsAndContinuesPastNestedItems() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("b", .numberedList),
            paragraph("c", .bulletedList, indent: 1),
            paragraph("d", .numberedList),
        ]
        XCTAssertEqual(markdown(content), "1. a\n2. b\n    - c\n3. d")
    }

    func testNumbersNestedListsSeparately() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("x", .numberedList, indent: 1),
            paragraph("y", .numberedList, indent: 1),
            paragraph("b", .numberedList),
            paragraph("z", .numberedList, indent: 1),
        ]
        XCTAssertEqual(markdown(content), "1. a\n    1. x\n    2. y\n2. b\n    1. z")
    }

    func testRestartsNumberingAfterOtherBlocks() {
        let content = [
            paragraph("a", .numberedList),
            paragraph("b", .numberedList),
            paragraph("Between"),
            paragraph("c", .numberedList),
        ]
        XCTAssertEqual(markdown(content), "1. a\n2. b\n\nBetween\n\n1. c")
    }

    func testStartsNumberingAtTheStartingNumber() {
        let content = [
            paragraph("e", .numberedList, startingNumber: 5),
            paragraph("f", .numberedList, startingNumber: 5),
        ]
        XCTAssertEqual(markdown(content), "5. e\n6. f")
    }

    func testRendersBulletedAndDashedLists() {
        let content = [
            paragraph("bullet", .bulletedList),
            paragraph("dash", .dashedList),
        ]
        XCTAssertEqual(markdown(content), "- bullet\n- dash")
    }

    func testAlignsContinuationLinesWithTheItemText() {
        let content = [
            paragraph("one\u{2028}two", .numberedList),
            paragraph("three\u{2028}four", .bulletedList, indent: 1),
        ]
        XCTAssertEqual(markdown(content), "1. one\n   two\n    - three\n      four")
    }

    func testEscapesMarkersAtTheStartOfListItems() {
        XCTAssertEqual(markdown([paragraph("- dash", .bulletedList)]), #"- \- dash"#)
    }

    // MARK: - Checklists

    func testRendersChecklists() {
        let content = [
            paragraph("milk", .checklist),
            paragraph("eggs", .checklist, isChecked: true),
            Note.Paragraph(style: Note.ParagraphStyle(kind: .checklist)),
        ]
        XCTAssertEqual(markdown(content), "- [ ] milk\n- [x] eggs\n- [ ]")
    }

    // MARK: - Code

    func testRendersMonospacedParagraphsAsOneCodeBlock() {
        let content = [
            paragraph("Intro"),
            paragraph("let a = b * c_d", .monospaced),
            paragraph("print(a)\u{2028}// done", .monospaced),
            paragraph("After"),
        ]
        XCTAssertEqual(
            markdown(content),
            "Intro\n\n```\nlet a = b * c_d\nprint(a)\n// done\n```\n\nAfter"
        )
    }

    func testLengthensFenceBeyondBacktickRunsInCode() {
        XCTAssertEqual(
            markdown([paragraph("``` and ``", .monospaced)]),
            "````\n``` and ``\n````"
        )
        XCTAssertEqual(
            markdown([paragraph("`` only", .monospaced)]),
            "```\n`` only\n```"
        )
    }

    func testLeavesAttachmentTextUnescapedInCode() {
        let content = [
            Note.Paragraph(
                style: Note.ParagraphStyle(kind: .monospaced),
                runs: [
                    Note.TextRun(text: "tag: "),
                    attachmentRun(type: inlineType("hashtag"), displayText: "#to_do"),
                ]
            )
        ]
        XCTAssertEqual(markdown(content), "```\ntag: #to_do\n```")
    }

    // MARK: - Block quotes

    func testRendersBlockQuotes() {
        let content = [
            paragraph("Intro"),
            paragraph("first\u{2028}second", isBlockQuote: true),
            paragraph("third", isBlockQuote: true),
        ]
        XCTAssertEqual(markdown(content), "Intro\n\n> first\n> second\n> third")
    }

    func testQuotesListItemsAndTheirContinuationLines() {
        let content = [paragraph("a\u{2028}b", .bulletedList, isBlockQuote: true)]
        XCTAssertEqual(markdown(content), "> - a\n>   b")
    }

    // MARK: - Tables

    func testRendersTableWithHeaderRowAndEscapedCells() {
        let table = Note.Table(rows: [
            [cell("Name"), cell("Qty")],
            [cell("a|b"), cell("line1", "line2")],
            [cell("*x*"), cell("trailing", "")],
        ])
        let content = [paragraph("Intro"), tableParagraph(table), paragraph("After")]
        XCTAssertEqual(
            markdown(content),
            """
            Intro

            | Name | Qty |
            | --- | --- |
            | a\\|b | line1<br>line2 |
            | \\*x\\* | trailing |

            After
            """
        )
    }

    func testRendersTableAsTabSeparatedPlainText() {
        let table = Note.Table(rows: [
            [cell("Name"), cell("Qty")],
            [cell("*x*"), cell("2")],
        ])
        XCTAssertEqual(plain([tableParagraph(table)]), "Name\tQty\n*x*\t2")
    }

    func testFallsBackToTableSummary() {
        let summarized = attachmentRun(type: "com.apple.notes.table", summary: "Name Qty")
        let bare = attachmentRun(type: "com.apple.notes.table")
        XCTAssertEqual(markdown([Note.Paragraph(runs: [summarized])]), "Name Qty")
        XCTAssertEqual(markdown([Note.Paragraph(runs: [bare])]), "[Table]")
    }

    // MARK: - Links and attachments

    func testRendersWebLinks() {
        let titled = attachmentRun(
            type: "public.url",
            title: "Example [site]",
            url: URL(string: "https://example.com")
        )
        let untitled = attachmentRun(type: "public.url", url: URL(string: "https://example.com"))
        let content = [Note.Paragraph(runs: [Note.TextRun(text: "See "), titled, Note.TextRun(text: " now")])]

        XCTAssertEqual(markdown(content), #"See [Example \[site\]](https://example.com) now"#)
        XCTAssertEqual(plain(content), "See Example [site] (https://example.com) now")
        XCTAssertEqual(
            markdown([Note.Paragraph(runs: [untitled])]),
            "[https://example.com](https://example.com)"
        )
        XCTAssertEqual(plain([Note.Paragraph(runs: [untitled])]), "https://example.com")
    }

    func testRendersInlineAttachments() {
        let content = [
            Note.Paragraph(runs: [
                attachmentRun(type: inlineType("hashtag"), displayText: "#to_do"),
                Note.TextRun(text: " "),
                attachmentRun(type: inlineType("mention"), displayText: "@Ann"),
                Note.TextRun(text: " "),
                attachmentRun(
                    type: inlineType("link"),
                    displayText: "Other note",
                    tokenIdentifier: "applenotes:note/ABC"
                ),
                Note.TextRun(text: " = "),
                attachmentRun(type: inlineType("calculateresult"), displayText: "42"),
            ])
        ]
        XCTAssertEqual(
            markdown(content),
            #"#to\_do @Ann [Other note](applenotes:note/ABC) = 42"#
        )
        XCTAssertEqual(plain(content), "#to_do @Ann Other note = 42")
    }

    func testDescribesMediaAttachments() {
        let runs = [
            attachmentRun(type: "public.jpeg", fileName: "photo_1.jpg"),
            attachmentRun(type: "com.apple.drawing.2"),
            attachmentRun(type: "com.apple.paper.doc.scan", title: "Receipt"),
            attachmentRun(type: "com.adobe.pdf", title: "Manual"),
            attachmentRun(type: "public.mp3"),
            attachmentRun(type: "public.mpeg-4"),
            attachmentRun(type: "public.vcard"),
            attachmentRun(type: "public.data", fileName: "notes.bin"),
        ]
        XCTAssertEqual(
            markdown(runs.map { Note.Paragraph(runs: [$0]) }),
            [
                #"[Image: photo\_1.jpg]"#, "[Drawing]", "[Scanned document: Receipt]", "[PDF: Manual]",
                "[Audio]", "[Video]", "[Contact]", "[Attachment: notes.bin]",
            ].joined(separator: "\n")
        )
        XCTAssertEqual(plain([Note.Paragraph(runs: [runs[0]])]), "[Image: photo_1.jpg]")
    }

    func testDropsObjectReplacementCharactersOutsideAttachments() {
        XCTAssertEqual(markdown([paragraph("a\u{FFFC}b")]), "ab")
    }

    // MARK: - Plain text

    func testRendersPlainTextWithoutMarkup() {
        let content = [
            paragraph("Title", .title),
            paragraph("*literal*"),
            paragraph("item", .numberedList),
            paragraph("done", .checklist, isChecked: true),
            paragraph("let x = 1", .monospaced),
            paragraph("a\u{2028}b", isBlockQuote: true),
        ]
        XCTAssertEqual(plain(content), "Title\n*literal*\nitem\ndone\nlet x = 1\na\nb")
    }

    // MARK: - Helpers

    private func markdown(_ paragraphs: [Note.Paragraph]) -> String {
        NoteRenderer(format: .markdown).render(Note.Content(paragraphs: paragraphs))
    }

    private func plain(_ paragraphs: [Note.Paragraph]) -> String {
        NoteRenderer(format: .plain).render(Note.Content(paragraphs: paragraphs))
    }

    private func paragraph(
        _ text: String,
        _ kind: Note.ParagraphStyle.Kind = .body,
        indent: Int = 0,
        isChecked: Bool = false,
        startingNumber: Int? = nil,
        isBlockQuote: Bool = false
    ) -> Note.Paragraph {
        Note.Paragraph(
            style: Note.ParagraphStyle(
                kind: kind,
                indent: indent,
                isChecked: isChecked,
                startingNumber: startingNumber,
                isBlockQuote: isBlockQuote
            ),
            runs: [Note.TextRun(text: text)]
        )
    }

    /// A table cell with a paragraph for each line, where an empty line is an empty paragraph.
    private func cell(_ lines: String...) -> Note.Content {
        Note.Content(paragraphs: lines.map { $0.isEmpty ? Note.Paragraph() : paragraph($0) })
    }

    private func tableParagraph(_ table: Note.Table) -> Note.Paragraph {
        Note.Paragraph(runs: [attachmentRun(type: "com.apple.notes.table", table: table)])
    }

    private func inlineType(_ name: String) -> String {
        "com.apple.notes.inlinetextattachment." + name
    }

    private func attachmentRun(
        type: String,
        displayText: String? = nil,
        tokenIdentifier: String? = nil,
        title: String? = nil,
        url: URL? = nil,
        fileName: String? = nil,
        summary: String? = nil,
        table: Note.Table? = nil
    ) -> Note.TextRun {
        Note.TextRun(
            text: "\u{FFFC}",
            attachment: Note.Attachment(
                id: Note.Attachment.ID(UUID().uuidString)!,
                typeIdentifier: type,
                displayText: displayText,
                tokenIdentifier: tokenIdentifier,
                title: title,
                url: url,
                fileName: fileName,
                summary: summary,
                table: table
            )
        )
    }
}
