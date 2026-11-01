import Foundation
import Envelope
import SQLite3
import XCTest

final class MailTests: XCTestCase {
    func testPackageErrorsPreserveToolGuidance() throws {
        XCTAssertThrowsError(try MailService.shared.mailboxID(from: "INBOX")) { error in
            let description = String(describing: MailToolError(underlying: error))
            XCTAssertTrue(description.contains("@id"))
            XCTAssertTrue(description.contains("\"V10:12\""))
            XCTAssertTrue(description.contains("url field"))
        }
        XCTAssertEqual(try MailService.shared.mailboxID(from: "V10:12").description, "V10:12")
        XCTAssertThrowsError(try MailService.shared.mailboxID(from: "12"))
        XCTAssertEqual(
            String(
                describing: MailToolError(underlying: Envelope.Message.FetchRequest.ValidationError.limitOutOfRange)
            ),
            "Invalid argument: limit must be 1 through 100"
        )
        XCTAssertTrue(MailToolError(underlying: Envelope.MailError.databaseBusy).localizedDescription.contains("iMCP"))
    }

    func testSearchPageValueWithoutCount() {
        let value = Envelope.Store.SearchResult.pageValue(records: [], nextCursor: nil, indexedMessageCount: nil)
        let localIndex = value.objectValue?["localIndex"]?.objectValue
        XCTAssertEqual(localIndex?["indexedMessageCount"], .null)
        XCTAssertEqual(localIndex?["syncStatus"], "unknown")
        XCTAssertTrue(localIndex?["description"]?.stringValue?.contains("could not be counted") ?? false)
        XCTAssertEqual(value.objectValue?["itemListElement"], .array([]))
        XCTAssertEqual(value.objectValue?["nextCursor"], .null)
    }

    func testSearchPageValueWithCount() {
        let value = Envelope.Store.SearchResult.pageValue(records: [], nextCursor: nil, indexedMessageCount: 42)
        let localIndex = value.objectValue?["localIndex"]?.objectValue
        XCTAssertEqual(localIndex?["indexedMessageCount"], .int(42))
        XCTAssertTrue(localIndex?["description"]?.stringValue?.contains("before search filters") ?? false)
    }

    func testCompositionEncodingAndFailure() throws {
        let composition = MailComposition(
            to: "a@example.com,b@example.com",
            cc: "c@example.com",
            bcc: "d@example.com",
            subject: "A & B?#% café",
            body: "one\ntwo &+?#%"
        )
        let url = try composition.url
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a%40example.com,b%40example.com?cc=c%40example.com&bcc="))
        XCTAssertTrue(url.absoluteString.contains("subject=A%20%26%20B%3F%23%25%20caf%C3%A9"))
        XCTAssertTrue(url.absoluteString.contains("body=one%0D%0Atwo%20%26%2B%3F%23%25"))
        XCTAssertThrowsError(try MailComposition(to: "a@example.com\r\nBcc: x@example.com").url)
        XCTAssertThrowsError(try MailComposition(subject: "Hi\nBcc: x").url)
        XCTAssertThrowsError(try composition.open(using: { _ in false })) { error in
            XCTAssertEqual(error as? MailError, .composeFailed)
            XCTAssertEqual(
                String(describing: error),
                "The default email app could not open the compose URL."
            )
        }
        var opened: URL?
        try composition.open {
            opened = $0; return true
        }
        XCTAssertEqual(opened, url)
        XCTAssertEqual(try MailComposition().url.absoluteString, "mailto:")
    }
}

/// Tests that run the Mail tools against a synthetic Mail folder.
final class MailIndexTests: XCTestCase {
    private var fixture: MailFixture!
    private var service: MailService!

    override func setUpWithError() throws {
        fixture = try MailFixture()
        service = MailService(mailDirectoryURL: fixture.root)
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    func testMailboxesListReadsTheIndexAndAccountMap() async throws {
        let result = try await call("mail_mailboxes_list")
        let mailboxes = try XCTUnwrap(result.objectValue?["itemListElement"]?.arrayValue)
        XCTAssertEqual(mailboxes.compactMap { $0.objectValue?["@id"]?.stringValue }, ["V10:2", "V10:1"])
        XCTAssertEqual(mailboxes.compactMap { $0.objectValue?["name"]?.stringValue }, ["Archive", "INBOX"])
        let account = try XCTUnwrap(mailboxes.first?.objectValue?["account"]?.objectValue)
        XCTAssertEqual(account["@id"], .string(MailFixture.accountID))
        XCTAssertEqual(account["email"], "alice@example.com")
    }

    func testSearchReturnsNewestFirstWithUnixEpochDates() async throws {
        let result = try await call("mail_messages_search")
        XCTAssertEqual(rowIDs(result), [3, 2, 1, 4])
        XCTAssertEqual(result.objectValue?["nextCursor"], .null)
        XCTAssertEqual(result.objectValue?["localIndex"]?.objectValue?["indexedMessageCount"], 4)

        let newest = try XCTUnwrap(result.objectValue?["itemListElement"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(newest["@id"], "V10:1:3")
        XCTAssertEqual(newest["mailbox"], "V10:1")
        XCTAssertEqual(newest["subject"], "Budget follow-up")
        XCTAssertEqual(newest["sender"]?.objectValue?["email"], "alice@example.com")
        // The index stores seconds since 1970, so another epoch would shift this date by years.
        XCTAssertEqual(newest["dateReceived"], "2026-01-16T09:00:00Z")
        XCTAssertEqual(newest["isRead"], false)
    }

    func testSearchFiltersCombine() async throws {
        let alice = try await call("mail_messages_search", ["sender": "ALICE", "subject": "budget"])
        XCTAssertEqual(rowIDs(alice), [3, 1])

        let unread = try await call("mail_messages_search", ["isRead": false])
        XCTAssertEqual(rowIDs(unread), [3, 1])

        let archive = try await call("mail_messages_search", ["mailbox": "V10:2"])
        XCTAssertEqual(rowIDs(archive), [4])
        XCTAssertEqual(archive.objectValue?["localIndex"]?.objectValue?["indexedMessageCount"], 1)

        do {
            _ = try await call("mail_messages_search", ["mailbox": "V10:99"])
            XCTFail("A mailbox that is not in the index must fail.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("mailbox does not exist in the local index"))
        }
    }

    func testSearchDateRangeIncludesStartAndExcludesEnd() async throws {
        let day = try await call(
            "mail_messages_search",
            ["start": "2026-01-15T00:00:00Z", "end": "2026-01-16T00:00:00Z"]
        )
        XCTAssertEqual(rowIDs(day), [2, 1])

        let bounds = try await call(
            "mail_messages_search",
            ["start": "2026-01-15T09:00:00Z", "end": "2026-01-15T12:00:00Z"]
        )
        XCTAssertEqual(rowIDs(bounds), [1])

        let offset = try await call(
            "mail_messages_search",
            ["start": "2026-01-15T10:00:00+01:00", "end": "2026-01-15T13:00:00+01:00"]
        )
        XCTAssertEqual(rowIDs(offset), [1])

        do {
            _ = try await call("mail_messages_search", ["start": "2026-01-16", "end": "2026-01-15T00:00:00Z"])
            XCTFail("A start date after the end date must fail.")
        } catch {
            XCTAssertEqual(String(describing: error), "Invalid argument: start must be before end")
        }
    }

    func testDateOnlyRangeIncludesTheWholeLocalDay() async throws {
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let expected = MailFixture.rows
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date > $1.date }
            .map(\.rowID)

        let result = try await call("mail_messages_search", ["start": "2026-01-15", "end": "2026-01-15"])
        XCTAssertEqual(rowIDs(result), expected)
    }

    func testCursorPagesStayStableWhenMailArrives() async throws {
        let first = try await call("mail_messages_search", ["limit": 3])
        XCTAssertEqual(rowIDs(first), [3, 2, 1])
        let cursor = try XCTUnwrap(first.objectValue?["nextCursor"]?.stringValue)

        // Automatic checkpoints are off, so the new row is only in the write-ahead log.
        try fixture.insert(
            MailFixture.Row(
                rowID: 5,
                mailbox: 1,
                subject: "New arrival",
                sender: "dave@example.com",
                date: MailFixture.date("2026-01-17T09:00:00Z"),
                isRead: false
            )
        )

        let second = try await call("mail_messages_search", ["limit": 3, "cursor": .string(cursor)])
        XCTAssertEqual(rowIDs(second), [4])
        XCTAssertEqual(second.objectValue?["nextCursor"], .null)

        let fresh = try await call("mail_messages_search", ["limit": 3])
        XCTAssertEqual(rowIDs(fresh), [5, 3, 2])

        do {
            _ = try await call("mail_messages_search", ["cursor": "not a cursor"])
            XCTFail("A malformed cursor must fail.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cursor must be a nextCursor value"))
        }
    }

    func testReadReturnsTheMessageContent() async throws {
        try fixture.writeMessage(
            rowID: 1,
            mime: """
                Message-ID: <message-1@example.com>
                From: alice@example.com
                Subject: Quarterly budget
                MIME-Version: 1.0
                Content-Type: multipart/mixed; boundary=b

                --b
                Content-Type: text/plain; charset=utf-8

                The draft budget is attached.
                --b
                Content-Type: text/csv
                Content-Disposition: attachment; filename="budget.csv"

                item,amount
                --b--
                """
        )

        let search = try await call("mail_messages_search", ["subject": "quarterly"])
        let id = try XCTUnwrap(
            search.objectValue?["itemListElement"]?.arrayValue?.first?.objectValue?["@id"]?.stringValue
        )
        XCTAssertEqual(id, "V10:1:1")

        let result = try await call("mail_messages_read", ["id": .string(id)])
        let content = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(content["@id"], "V10:1:1")
        XCTAssertEqual(content["text"], "The draft budget is attached.")
        XCTAssertEqual(content["encodingFormat"], "text/plain")
        XCTAssertEqual(
            content["attachment"]?.arrayValue,
            [["name": "budget.csv", "encodingFormat": "text/csv", "isStoredSeparately": false]]
        )
        let headers = try XCTUnwrap(content["headers"]?.arrayValue)
        XCTAssertTrue(headers.contains(["name": "Subject", "value": "Quarterly budget"]))
    }

    func testReadReturnsTheTextOfAPartialMessage() async throws {
        // Mail leaves the body of each part that it stores separately empty,
        // and records the original length in X-Apple-Content-Length.
        try fixture.writeMessage(
            rowID: 1,
            mime: """
                Message-ID: <message-1@example.com>
                Subject: Quarterly budget
                MIME-Version: 1.0
                Content-Type: multipart/mixed; boundary=b

                --b
                Content-Type: multipart/related; boundary=r

                --r
                Content-Type: text/html; charset=utf-8

                <p>The draft budget is attached.</p><img src="cid:logo">
                --r
                Content-Type: image/png
                Content-Disposition: inline
                Content-Transfer-Encoding: base64
                Content-ID: <logo>
                X-Apple-Content-Length: 2978

                --r--

                --b
                Content-Type: application/pdf; name=budget.pdf
                Content-Disposition: attachment; filename=budget.pdf
                Content-Transfer-Encoding: base64
                X-Apple-Content-Length: 59336

                --b--
                """,
            isPartial: true
        )

        let result = try await call("mail_messages_read", ["id": "V10:1:1"])
        let content = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(content["text"], #"<p>The draft budget is attached.</p><img src="cid:logo">"#)
        XCTAssertEqual(content["encodingFormat"], "text/html")
        XCTAssertEqual(
            content["attachment"]?.arrayValue,
            [
                ["name": .null, "encodingFormat": "image/png", "isStoredSeparately": true],
                ["name": "budget.pdf", "encodingFormat": "application/pdf", "isStoredSeparately": true],
            ]
        )
    }

    func testReadFailsForAnotherMessageOrAMissingFile() async throws {
        // The file's Message-ID does not match the index row for message 2.
        try fixture.writeMessage(rowID: 2, mime: "Message-ID: <someone-else@example.com>\n\nBody")
        do {
            _ = try await call("mail_messages_read", ["id": "V10:1:2"])
            XCTFail("A file for another message must fail.")
        } catch {
            XCTAssertTrue(error is MailToolError)
        }

        do {
            _ = try await call("mail_messages_read", ["id": "V10:1:3"])
            XCTFail("A message without a file must fail.")
        } catch {
            XCTAssertTrue(error is MailToolError)
        }
    }

    private func call(_ tool: String, _ arguments: [String: Value] = [:]) async throws -> Value {
        let result = try await service.call(tool: tool, with: arguments)
        return try XCTUnwrap(result, "No tool is named \(tool).")
    }

    /// Returns the message row identifiers of a search result, in order.
    private func rowIDs(_ result: Value) -> [Int64] {
        (result.objectValue?["itemListElement"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["@id"]?.stringValue.flatMap(Envelope.Message.Identifier.init)?.rowID
        }
    }
}

/// A synthetic Mail folder with one store, `V10`, one account, and two mailboxes.
///
/// The index uses WAL journal mode with automatic checkpoints off,
/// so rows stay in the write-ahead log while the writer connection is open.
/// As in Mail's index, `date_received` holds seconds since 1970.
/// Deinitialization closes the writer and removes the folder.
private final class MailFixture {
    struct Failure: Error {
        let message: String
    }

    /// A message row in the synthetic index.
    struct Row {
        let rowID: Int64
        let mailbox: Int64
        let subject: String
        let sender: String
        let date: Date
        let isRead: Bool
    }

    static let accountID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    /// The messages in the index. Mailbox 1 is the inbox and mailbox 2 is the archive.
    static let rows = [
        Row(
            rowID: 1,
            mailbox: 1,
            subject: "Quarterly budget",
            sender: "alice@example.com",
            date: date("2026-01-15T09:00:00Z"),
            isRead: false
        ),
        Row(
            rowID: 2,
            mailbox: 1,
            subject: "Lunch plans",
            sender: "bob@example.com",
            date: date("2026-01-15T12:00:00Z"),
            isRead: true
        ),
        Row(
            rowID: 3,
            mailbox: 1,
            subject: "Budget follow-up",
            sender: "alice@example.com",
            date: date("2026-01-16T09:00:00Z"),
            isRead: false
        ),
        Row(
            rowID: 4,
            mailbox: 2,
            subject: "Old receipt",
            sender: "carol@example.com",
            date: date("2025-12-01T00:00:00Z"),
            isRead: true
        ),
    ]

    /// The Mail folder.
    let root: URL
    private var writer: OpaquePointer?

    /// The store directory.
    var version: URL { root.appendingPathComponent("V10") }
    /// The `.mbox` folder of the inbox, which Mail names after the account UUID.
    var inbox: URL { version.appendingPathComponent("\(Self.accountID)/INBOX.mbox") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mailData = version.appendingPathComponent("MailData")
        try FileManager.default.createDirectory(
            at: mailData.appendingPathComponent("Signatures"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: inbox.appendingPathComponent("Data/Messages"),
            withIntermediateDirectories: true
        )
        let accounts = [Self.accountID: ["AccountURL": "imap://alice%40example.com@imap.example.com"]]
        try PropertyListSerialization.data(fromPropertyList: accounts, format: .xml, options: 0)
            .write(to: mailData.appendingPathComponent("Signatures/AccountsMap.plist"))

        guard sqlite3_open(mailData.appendingPathComponent("Envelope Index").path, &writer) == SQLITE_OK else {
            throw Failure(message: "The index could not be created.")
        }
        try execute(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, mailbox INTEGER, subject INTEGER, sender INTEGER, date_received INTEGER, read INTEGER, message_id TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT);
            CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
            INSERT INTO mailboxes VALUES (1, 'imap://\(Self.accountID)/INBOX'), (2, 'imap://\(Self.accountID)/Archive');
            """
        )
        for row in Self.rows {
            try insert(row)
        }
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: root)
    }

    /// Adds a message through the writer connection, with its own subject and address rows.
    func insert(_ row: Row) throws {
        try execute(
            """
            INSERT INTO subjects VALUES (\(row.rowID), '\(row.subject)');
            INSERT INTO addresses VALUES (\(row.rowID), '\(row.sender)');
            INSERT INTO messages VALUES (\(row.rowID), \(row.mailbox), \(row.rowID), \(row.rowID), \
            \(Int(row.date.timeIntervalSince1970)), \(row.isRead ? 1 : 0), 'message-\(row.rowID)@example.com');
            """
        )
    }

    /// Writes the `.emlx` file of an inbox message: a byte count, the MIME message, and a property list.
    /// - Parameter isPartial: Whether to write a `.partial.emlx` file, as Mail does
    ///   when it stores some parts of the message in separate files.
    func writeMessage(rowID: Int64, mime: String, isPartial: Bool = false) throws {
        let payload = Data(mime.utf8)
        let data = Data("\(payload.count)\n".utf8) + payload + Data("\n<plist version=\"1.0\"><dict/></plist>\n".utf8)
        let name = isPartial ? "\(rowID).partial.emlx" : "\(rowID).emlx"
        try data.write(to: inbox.appendingPathComponent("Data/Messages/\(name)"))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(writer)))
        }
    }

    /// Returns the date for an ISO 8601 timestamp with a time zone.
    static func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string) ?? .distantPast
    }
}
