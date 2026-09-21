import Foundation
import SQLite3
import XCTest

final class MailTests: XCTestCase {
    private var root: URL!
    private var writer: OpaquePointer?
    private var version: URL { root.appendingPathComponent("V10") }
    private var mailbox: URL { version.appendingPathComponent("account/Inbox.mbox") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: version.appendingPathComponent("MailData"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open(version.appendingPathComponent("MailData/Envelope Index").path, &writer), SQLITE_OK)
        try execute(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, mailbox INTEGER, subject INTEGER, sender INTEGER, date_received INTEGER, read INTEGER, message_id TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT);
            CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
            INSERT INTO subjects VALUES (1, 'Budget 100%'), (2, 'Other');
            INSERT INTO addresses VALUES (1, 'alice@example.com'), (2, 'bob@example.com');
            INSERT INTO mailboxes VALUES (1, '\(mailbox.absoluteString)'), (2, '\(version.appendingPathComponent("account/Other.mbox").absoluteString)');
            INSERT INTO messages VALUES (1,1,1,1,100,0,'one@example.com'), (2,2,1,1,200,1,'two@example.com'), (3,1,2,2,300,0,'three@example.com');
            INSERT INTO labels VALUES (2,1);
            """
        )
    }

    override func tearDownWithError() throws {
        sqlite3_close(writer)
        writer = nil
        try FileManager.default.removeItem(at: root)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw MailError.queryFailed(String(cString: sqlite3_errmsg(writer)))
        }
    }

    private func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }

    func testSearchFiltersPaginationAndLiveWAL() throws {
        let database = try MailDatabase(root: root)
        XCTAssertEqual(try database.fetch(.init()).map(\.id), [3, 2, 1])
        var query = MailRecord.FetchRequest()
        query.sender = "ALICE"
        query.subject = "%"
        query.mailbox = 1
        query.startDate = Date(timeIntervalSince1970: 100)
        query.endDate = Date(timeIntervalSince1970: 200)
        query.isRead = false
        XCTAssertEqual(try database.fetch(query).map(\.id), [1])
        query.endDate = Date(timeIntervalSince1970: 201)
        query.isRead = true
        XCTAssertEqual(try database.fetch(query).map(\.id), [2])
        query = .init()
        query.limit = 1
        query.offset = 1
        XCTAssertEqual(try database.fetch(query).map(\.id), [2])
        try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
        XCTAssertEqual(try database.fetch(.init()).first?.id, 4)
        query.limit = 101
        XCTAssertThrowsError(try database.fetch(query))
        query.limit = 1
        query.offset = -1
        XCTAssertThrowsError(try database.fetch(query))
        query = .init()
        query.sender = "' OR 1=1 --"
        XCTAssertTrue(try database.fetch(query).isEmpty)
    }

    func testDefaultAndMaximumLimits() throws {
        try execute(
            """
            WITH RECURSIVE numbers(n) AS (SELECT 4 UNION ALL SELECT n+1 FROM numbers WHERE n<110)
            INSERT INTO messages SELECT n,1,1,1,400+n,0,'id@example.com' FROM numbers;
            """
        )
        let database = try MailDatabase(root: root)
        XCTAssertEqual(try database.fetch(.init()).count, 30)
        var request = MailRecord.FetchRequest()
        request.limit = 100
        XCTAssertEqual(try database.fetch(request).count, 100)
        XCTAssertThrowsError(try database.query("DELETE FROM messages") { _ in })
        XCTAssertEqual(try database.mailboxes().count, 2)
    }

    func testDiscoveryAndUnsupportedSchema() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V99"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(try MailDatabase(root: root).versionURL.lastPathComponent, "V10")
        try execute("DROP TABLE subjects")
        XCTAssertThrowsError(try MailDatabase(root: root)) { error in
            XCTAssertEqual(error as? MailError, .unsupportedSchema)
        }
    }

    func testPaddedByteCountPreservesMIMEBoundaries() throws {
        let payload = Data("Subject: Padding\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé".utf8)
        let count = String(payload.count)
        let padded = count.padding(toLength: 10, withPad: " ", startingAt: 0)
        for prefix in [count + "\n", padded + "\n", padded + "\r\n"] {
            let data = Data(prefix.utf8) + payload + Data("\n<plist>not message content</plist>".utf8)
            let content = try MailContent(emlx: data)
            XCTAssertEqual(content.body, "café")
            XCTAssertEqual(content.headers.first?.value, "Padding")
        }
        XCTAssertThrowsError(try MailContent(emlx: Data("999       \n".utf8) + payload)) { error in
            XCTAssertEqual(error as? MailError, .partialMessage)
        }
    }

    func testInvalidByteCountsRemainRejected() throws {
        for prefix in ["", "          ", "1 2", "12x", "+12", "-12", "0", "99999999999999999999999"] {
            XCTAssertThrowsError(try MailContent(emlx: Data((prefix + "\nSubject: Test\n\nBody").utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("byte-count prefix"))
            }
        }
    }

    func testByteCountAndEncodedHeaders() throws {
        let content = try MailContent(
            emlx: emlx("Subject: =?utf-8?B?Y2Fmw6k=?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé")
        )
        XCTAssertEqual(content.body, "café")
        XCTAssertEqual(content.headers.first?.value, "café")
        XCTAssertFalse(content.body.contains("plist"))
        XCTAssertThrowsError(try MailContent(emlx: Data("999\nSubject: x\n\nshort".utf8)))
        XCTAssertThrowsError(try MailContent(emlx: Data("oops\nhi".utf8)))
        XCTAssertThrowsError(try MailContent(emlx: emlx("no headers")))
        XCTAssertThrowsError(
            try MailContent(
                emlx: emlx("Subject: Broken\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\n%%%")
            )
        )
        XCTAssertThrowsError(
            try MailContent(emlx: emlx("Subject: Broken\nContent-Type: text/plain; charset=unknown-charset\n\ntext"))
        )
        XCTAssertThrowsError(
            try MailContent(
                emlx: emlx(
                    "Subject: Broken\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n/w=="
                )
            )
        )
    }

    func testMultipartAndCharacterEncoding() throws {
        let mime = """
            Subject: MIME
            Content-Type: multipart/mixed; boundary=outer

            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/plain; charset=iso-8859-1
            Content-Transfer-Encoding: quoted-printable

            caf=E9
            --inner
            Content-Type: text/html

            <p>HTML</p>
            --inner--
            --outer
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            YQ==
            --outer--
            """
        let content = try MailContent(emlx: emlx(mime))
        XCTAssertEqual(content.mediaType, "text/plain")
        XCTAssertTrue(content.body.contains("café"))
        XCTAssertEqual(content.attachments, ["report.pdf"])
        XCTAssertThrowsError(try MailContent(emlx: emlx(mime.replacingOccurrences(of: "--outer--", with: ""))))
        let html = try MailContent(
            emlx: emlx("Subject: HTML\nContent-Type: text/html\n\n<img src=\"https://example.com/x\">")
        )
        XCTAssertEqual(html.mediaType, "text/html")
        XCTAssertTrue(html.body.contains("https://example.com/x"))
        XCTAssertThrowsError(
            try MailContent(emlx: emlx("Subject: Secret\nContent-Type: application/pkcs7-mime\n\nencrypted"))
        )
    }

    func testFileSeparationIdentityAndStaleCache() throws {
        let database = try MailDatabase(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).last)
        let files = MailFiles()
        XCTAssertThrowsError(try files.read(record, version: version))
        let url = mailbox.appendingPathComponent("1.emlx")
        try emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect").write(to: url)
        XCTAssertEqual(try files.read(record, version: version).body, "Correct")
        try emlx("Message-ID: <wrong@example.com>\nSubject: Wrong\n\nWrong").write(to: url)
        XCTAssertThrowsError(try files.read(record, version: version))
        try FileManager.default.removeItem(at: url)
        let other = version.appendingPathComponent("account/Other.mbox")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try emlx("Message-ID: <one@example.com>\nSubject: One\n\nWrong mailbox").write(
            to: other.appendingPathComponent("1.emlx")
        )
        XCTAssertThrowsError(try files.read(record, version: version))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other.appendingPathComponent("1.emlx"))
        XCTAssertThrowsError(try files.read(record, version: version))
        XCTAssertThrowsError(try files.mailboxDirectory("file:///tmp/Outside.mbox", version: version))
    }

    func testIdentifierRoundTripAndLookup() throws {
        let database = try MailDatabase(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).first)
        XCTAssertEqual(record.identifier.description, "V10:1:3")
        XCTAssertEqual(MailRecord.Identifier("V10:1:3"), record.identifier)
        XCTAssertEqual(try database.record(for: record.identifier).id, 3)
        for invalid in ["", "V10:1", "V10:1:3:4", ":1:3", "V10:0:3", "V10:1:-3", "V10:x:3"] {
            XCTAssertNil(MailRecord.Identifier(invalid), invalid)
        }
        XCTAssertThrowsError(try database.record(for: .init(store: "V9", mailbox: 1, message: 3))) { error in
            XCTAssertEqual(error as? MailError, .storeChanged)
        }
        // A label gives mailbox membership in search, but the identifier names the home mailbox.
        XCTAssertThrowsError(try database.record(for: .init(store: "V10", mailbox: 1, message: 2))) { error in
            XCTAssertEqual(error as? MailError, .messageNotFound)
        }
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
        }
        var opened: URL?
        try composition.open {
            opened = $0; return true
        }
        XCTAssertEqual(opened, url)
        XCTAssertEqual(try MailComposition().url.absoluteString, "mailto:")
    }
}
