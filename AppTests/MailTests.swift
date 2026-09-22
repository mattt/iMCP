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

    private func checkpoint() -> Int32 {
        sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    func testWALWriterCanCommitDuringReadAndCheckpointAfterward() throws {
        let database = try MailDatabase(root: root)
        var wroteDuringRead = false
        let ids = try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { row in
            if !wroteDuringRead {
                try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
                wroteDuringRead = true
                // A reader still delays WAL reset, even with SQLITE_OPEN_READONLY.
                XCTAssertEqual(checkpoint(), SQLITE_BUSY)
            }
            return row.integer(0)
        }
        XCTAssertEqual(ids, [1, 2, 3])
        // Finalizing the statement releases its read lock, before connection close.
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        XCTAssertEqual(try database.fetch(.init()).first?.id, 4)
    }

    func testSeparateWriterProcessCanCommitAndThenResetWAL() throws {
        func runWriter(_ sql: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", version.appendingPathComponent("MailData/Envelope Index").path, sql]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text
        }

        // Allow for process startup in this synthetic contention test.
        // The separate deadline test exercises the production 100 ms budget.
        let database = try MailDatabase(root: root, queryTimeLimit: .seconds(2))
        var wroteDuringRead = false
        try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { _ in
            if !wroteDuringRead {
                let result = try runWriter(
                    """
                    INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com');
                    PRAGMA wal_checkpoint(TRUNCATE);
                    """
                )
                XCTAssertTrue(result.hasPrefix("1|"), result)
                wroteDuringRead = true
            }
        }
        XCTAssertTrue(wroteDuringRead)
        XCTAssertEqual(try runWriter("PRAGMA wal_checkpoint(TRUNCATE); SELECT count(*) FROM messages;"), "0|0|0\n4\n")
    }

    func testQueryDeadlineReleasesReadLock() throws {
        let database = try MailDatabase(root: root)
        let start = ContinuousClock.now
        XCTAssertThrowsError(
            try database.query(
                """
                WITH RECURSIVE counter(n) AS (
                    SELECT ROWID FROM messages
                    UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                ) SELECT sum(n) FROM counter
                """
            ) { $0.integer(0) }
        ) { error in
            XCTAssertEqual(error as? MailError, .queryTimedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        // An interrupted statement must not poison the next request.
        XCTAssertEqual(try database.fetch(.init()).count, 3)
    }

    func testThrownTransformReleasesReadLock() throws {
        let database = try MailDatabase(root: root)
        XCTAssertThrowsError(
            try database.query("SELECT ROWID FROM messages") { _ -> Int in
                throw MailError.messageMismatch
            }
        ) { error in
            XCTAssertEqual(error as? MailError, .messageMismatch)
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
    }

    func testCancellationReleasesReadLockAndConnectionAdmission() async throws {
        let root = try XCTUnwrap(root)
        let task = Task {
            let database = try MailDatabase(root: root)
            return try database.query("SELECT ROWID FROM messages") { row in
                withUnsafeCurrentTask { $0?.cancel() }
                return row.integer(0)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {
            // Expected; no partial results are returned.
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        XCTAssertEqual(try MailDatabase(root: root).fetch(.init()).count, 3)
    }

    func testRejectsOverlappingConnectionsAndAllowsReopen() throws {
        let database = try MailDatabase(root: root)
        XCTAssertThrowsError(try MailDatabase(root: root)) { error in
            XCTAssertEqual(error as? MailError, .databaseBusy)
        }
        database.close()
        database.close()
        let reopened = try MailDatabase(root: root)
        XCTAssertEqual(try reopened.fetch(.init()).count, 3)
        XCTAssertThrowsError(try database.fetch(.init())) { error in
            XCTAssertEqual(error as? MailError, .indexNotReadable)
        }
    }

    @MainActor
    func testWorkerRejectsOverlapAndReleasesAdmissionAfterCancellation() async throws {
        let worker = MailWorker()
        let entered = expectation(description: "Worker started")
        // Only the dispatch worker waits on this semaphore, never an async task.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await worker.run { _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw MailError.queryTimedOut
                }
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await worker.run { _ in 2 }
            XCTFail("Expected the overlapping operation to be rejected")
        } catch {
            XCTAssertEqual(error as? MailError, .databaseBusy)
        }

        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation instead of the worker's result")
        } catch is CancellationError {
            // The worker must release admission before returning cancellation.
        }
        let result = try await worker.run { _ in 3 }
        XCTAssertEqual(result, 3)
    }

    func testWorkerCancellationInterruptsQueryAndReleasesReadLock() async throws {
        let root = try XCTUnwrap(root)
        let worker = MailWorker()
        let entered = expectation(description: "Query returned its first row")
        let task = Task {
            try await worker.run { cancellation in
                let database = try MailDatabase(root: root, queryTimeLimit: .seconds(5), cancellation: cancellation)
                defer { database.close() }
                return try database.query(
                    """
                    WITH RECURSIVE counter(n) AS (
                        SELECT ROWID FROM messages WHERE ROWID = 1
                        UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                    ) SELECT n FROM counter
                    """
                ) { row in
                    let n = row.integer(0)
                    if n == 1 { entered.fulfill() }
                    return n
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation of the query on the dispatch worker")
        } catch is CancellationError {
            // Cancellation must reach SQLite without the caller's task context.
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        let count = try await worker.run { cancellation in
            let database = try MailDatabase(root: root, cancellation: cancellation)
            defer { database.close() }
            return try database.fetch(.init()).count
        }
        XCTAssertEqual(count, 3)
    }

    func testWorkerDoesNotStartAlreadyCancelledOperation() async throws {
        let worker = MailWorker()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.run { _ in
                XCTFail("A canceled task must not start file or database work")
                return 1
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let result = try await worker.run { _ in 2 }
        XCTAssertEqual(result, 2)
    }

    func testBusyIndexFailsWithoutWaitingAndAllowsReopen() throws {
        try execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE messages SET read=1;")
        defer { try? execute("ROLLBACK; PRAGMA locking_mode=NORMAL;") }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try MailDatabase(root: root)) { error in
            XCTAssertEqual(error as? MailError, .databaseBusy)
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        try execute("ROLLBACK; PRAGMA locking_mode=NORMAL; SELECT * FROM messages;")
        XCTAssertEqual(try MailDatabase(root: root).fetch(.init()).count, 3)
    }

    func testRejectsRollbackJournalWithoutChangingIt() throws {
        try execute("PRAGMA journal_mode=DELETE;")
        XCTAssertThrowsError(try MailDatabase(root: root)) { error in
            XCTAssertEqual(error as? MailError, .unsupportedJournalMode)
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "PRAGMA journal_mode", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "delete")
        try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
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

    func testReceivedDateAndRangeUseUnixEpoch() throws {
        // Use literal timestamps and independently parsed calendar dates so the
        // fixture cannot hide an epoch change in both decoding and filtering.
        try execute(
            """
            INSERT INTO messages VALUES
                (4,1,1,1,1704067199,0,'before@example.com'),
                (5,1,1,1,1704067200,0,'start@example.com'),
                (6,1,1,1,1704153599,0,'last@example.com'),
                (7,1,1,1,1704153600,0,'end@example.com');
            """
        )
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2024-01-01T00:00:00Z"))
        let end = try XCTUnwrap(formatter.date(from: "2024-01-02T00:00:00Z"))
        let database = try MailDatabase(root: root)
        let record = try XCTUnwrap(database.fetch(.init(id: 5)).first)
        XCTAssertEqual(record.date, start)
        XCTAssertEqual(record.value.objectValue?["dateReceived"]?.stringValue, "2024-01-01T00:00:00Z")

        var request = MailRecord.FetchRequest()
        request.startDate = start
        request.endDate = end
        XCTAssertEqual(try database.fetch(request).map(\.id), [6, 5])
        request.endDate = nil
        XCTAssertEqual(try database.fetch(request).map(\.id), [7, 6, 5])
        request.startDate = nil
        request.endDate = end
        XCTAssertEqual(try database.fetch(request).map(\.id), [6, 5, 4, 3, 2, 1])
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

    func testListedMailboxIdentifierWorksAsSearchFilter() throws {
        let database = try MailDatabase(root: root)
        let listed = try XCTUnwrap(database.mailboxes().first { $0.id == 1 })
        let identifier = try XCTUnwrap(listed.value.objectValue?["@id"]?.stringValue)
        let request = MailRecord.FetchRequest(mailbox: try MailboxRecord.parseIdentifier(.string(identifier)))
        XCTAssertEqual(try database.fetch(request).map(\.id), [3, 2, 1])
        XCTAssertThrowsError(try MailboxRecord.parseIdentifier(.string(listed.url))) { error in
            XCTAssertTrue(error.localizedDescription.contains("@id"))
            XCTAssertTrue(error.localizedDescription.contains("\"12\""))
            XCTAssertTrue(error.localizedDescription.contains("url field"))
        }
        for invalid in ["", "0", "-1", "+1", " 1", "1.0", "INBOX", "9223372036854775808"] {
            XCTAssertThrowsError(try MailboxRecord.parseIdentifier(.string(invalid)), invalid)
        }
        XCTAssertThrowsError(try MailboxRecord.parseIdentifier(.int(1)))
        XCTAssertThrowsError(try database.search(.init(mailbox: 999))) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    func testSearchExplainsLocalIndexCoverage() throws {
        let database = try MailDatabase(root: root)
        // A label and home membership must count the message only once.
        try execute("INSERT INTO labels VALUES (1,1), (2,1)")
        var request = MailRecord.FetchRequest(subject: "No match", mailbox: 1)
        var result = try XCTUnwrap(database.search(request).objectValue)
        XCTAssertEqual(result["itemListElement"]?.arrayValue?.count, 0)
        XCTAssertEqual(result["localIndex"]?.objectValue?["indexedMessageCount"]?.intValue, 3)
        XCTAssertEqual(result["localIndex"]?.objectValue?["syncStatus"]?.stringValue, "unknown")

        request.subject = nil
        request.offset = 100
        result = try XCTUnwrap(database.search(request).objectValue)
        XCTAssertEqual(result["itemListElement"]?.arrayValue?.count, 0)
        XCTAssertEqual(result["localIndex"]?.objectValue?["indexedMessageCount"]?.intValue, 3)

        try execute("INSERT INTO mailboxes VALUES (3, 'imap://account/Empty')")
        result = try XCTUnwrap(database.search(.init(mailbox: 3)).objectValue)
        let coverage = try XCTUnwrap(result["localIndex"]?.objectValue)
        XCTAssertEqual(coverage["indexedMessageCount"]?.intValue, 0)
        XCTAssertEqual(coverage["syncStatus"]?.stringValue, "unknown")
        XCTAssertTrue(coverage["description"]?.stringValue?.contains("may not have indexed it yet") == true)

        try execute("DROP TABLE labels")
        result = try XCTUnwrap(database.search(.init(mailbox: 1)).objectValue)
        XCTAssertEqual(result["localIndex"]?.objectValue?["indexedMessageCount"]?.intValue, 2)
        result = try XCTUnwrap(database.search(.init()).objectValue)
        XCTAssertEqual(result["localIndex"]?.objectValue?["indexedMessageCount"]?.intValue, 3)
    }

    func testAccountLabelsAndMissingMetadata() throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"
        try execute(
            """
            UPDATE mailboxes SET url = 'imap://\(first)/INBOX' WHERE ROWID = 1;
            UPDATE mailboxes SET url = 'imap://\(second)/INBOX' WHERE ROWID = 2;
            INSERT INTO mailboxes VALUES (3, 'imap://\(third)/INBOX');
            INSERT INTO mailboxes VALUES (4, '\(version.appendingPathComponent(first + "/Archive.mbox").absoluteString)');
            """
        )
        let database = try MailDatabase(root: root)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
        let metadata = version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries: [String: Any] = [
            first: ["AccountURL": "imap://personal%2Bmail%40example.com@imap.example.com/"],
            second: ["AccountURL": "imap://work%40example.com@imap.example.com/"],
            third: ["AccountURL": "imap://username@imap.example.com/"],
            "invalid-entry": "not an account",
        ]
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0).write(to: metadata)
        let mailboxes = try database.mailboxes()
        let personal = try XCTUnwrap(mailboxes.first { $0.id == 1 })
        let work = try XCTUnwrap(mailboxes.first { $0.id == 2 })
        XCTAssertEqual(personal.name, work.name)
        XCTAssertEqual(personal.account?.email, "personal+mail@example.com")
        XCTAssertEqual(work.value.objectValue?["account"]?.objectValue?["email"]?.stringValue, "work@example.com")
        XCTAssertEqual(mailboxes.first { $0.id == 3 }?.account?.id, third)
        XCTAssertNil(mailboxes.first { $0.id == 3 }?.account?.email)
        XCTAssertEqual(mailboxes.first { $0.id == 4 }?.account?.email, "personal+mail@example.com")

        try Data("invalid plist".utf8).write(to: metadata)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
        try FileManager.default.removeItem(at: metadata)
        let outside = root.appendingPathComponent("Outside.plist")
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0).write(to: outside)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
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

    func testFileReadsAndMIMEParsingRespectCancellation() throws {
        let database = try MailDatabase(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).last)
        database.close()
        let files = MailFiles()
        let cancellation = MailCancellation()
        cancellation.cancel()
        // A canceled cold lookup must stop before reporting a missing file.
        XCTAssertThrowsError(try files.read(record, version: version, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let data = emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect")
        try data.write(to: mailbox.appendingPathComponent("1.emlx"))
        XCTAssertEqual(try files.read(record, version: version).body, "Correct")
        XCTAssertThrowsError(try files.read(record, version: version, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try MailContent(emlx: data, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try files.read(record, version: version).body, "Correct")
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
