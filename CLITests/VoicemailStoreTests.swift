import Foundation
import SQLite3
import XCTest

/// Tests for `VoicemailStore` against a synthesized store:
/// a fresh SQLite database and `Assets` tree in a temporary folder.
/// No row is ever copied from a real voicemail store.
final class VoicemailStoreTests: XCTestCase {
    private var folder: URL!
    private var store: VoicemailStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicemail-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = VoicemailStore(directoryPath: folder.path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    /// One row of the `ZSTOREDMESSAGE` table, with synthesized values.
    private struct Row {
        var id: Int
        var sender: String? = nil
        var created: Double = 0
        var duration: Double = 30
        var isRead: Bool = false
        var fileType: String? = nil
        var recordUUID: UUID? = nil
        var transcript: Data? = nil
        var deleted: Double? = nil
    }

    /// Fixed dates far from any real message, as seconds since the reference date.
    private let firstDate: Double = 700_000_000
    private let secondDate: Double = 750_000_000
    private let thirdDate: Double = 800_000_000

    private func makeStore(_ rows: [Row]) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.databasePath, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }

        try execute(
            """
            CREATE TABLE ZSTOREDMESSAGE (
                Z_PK INTEGER PRIMARY KEY,
                ZFROM TEXT,
                ZDATECREATED REAL,
                ZDATEDELETED REAL,
                ZDURATION REAL,
                ZISREAD INTEGER,
                ZFILETYPE TEXT,
                ZRECORDUUID BLOB,
                ZTRANSCRIPT BLOB
            )
            """,
            on: connection
        )

        for row in rows {
            try insert(row, into: connection)
        }
    }

    private func execute(_ sql: String, on connection: OpaquePointer?) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func insert(_ row: Row, into connection: OpaquePointer?) throws {
        let sql = """
            INSERT INTO ZSTOREDMESSAGE
                (Z_PK, ZFROM, ZDATECREATED, ZDATEDELETED, ZDURATION, ZISREAD, ZFILETYPE, ZRECORDUUID, ZTRANSCRIPT)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(row.id))
        bindText(row.sender, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, row.created)
        bindDouble(row.deleted, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, row.duration)
        sqlite3_bind_int(statement, 6, row.isRead ? 1 : 0)
        bindText(row.fileType, to: statement, at: 7)
        bindUUID(row.recordUUID, to: statement, at: 8)
        bindData(row.transcript, to: statement, at: 9)

        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func bindText(_ text: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let text else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, text, -1, transientDestructor)
    }

    private func bindDouble(_ value: Double?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bindUUID(_ uuid: UUID?, to statement: OpaquePointer?, at index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        withUnsafeBytes(of: uuid.uuid) { bytes in
            _ = sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                transientDestructor
            )
        }
    }

    private func bindData(_ data: Data?, to statement: OpaquePointer?, at index: Int32) {
        guard let data else {
            sqlite3_bind_null(statement, index)
            return
        }
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                transientDestructor
            )
        }
    }

    /// Writes a fake audio file for the row into the store's `Assets` tree.
    private func writeAudio(for row: Row, contents: String = "synthesized audio") throws {
        let uuid = try XCTUnwrap(row.recordUUID)
        let fileType = try XCTUnwrap(row.fileType)
        let url =
            folder
            .appendingPathComponent("Assets/\(uuid.uuidString.prefix(2))/\(uuid.uuidString).\(fileType)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    /// A transcript archive in the shape carrier voicemails use:
    /// a dictionary with the flattened text alongside per-segment detail.
    private func carrierTranscript() throws -> Data {
        let segments: [[String: Any]] = [
            ["text": "Hello", "confidence": 0.9],
            ["text": "leave a message", "confidence": 0.8],
        ]
        let root: [String: Any] = [
            "transcriptionString": "Hello, leave a message",
            "confidence": 0.85,
            "confidenceRating": 2,
            "segments": segments,
        ]
        return try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
    }

    /// A transcript archive in the shape FaceTime messages use:
    /// a bare array of segments.
    private func faceTimeTranscript() throws -> Data {
        let segments: [[String: Any]] = [
            ["text": "First sentence", "confidence": 0.7],
            ["text": "Second sentence", "confidence": 0.6],
        ]
        return try NSKeyedArchiver.archivedData(withRootObject: segments, requiringSecureCoding: false)
    }

    // MARK: - Fetching

    func testFetchMapsRowsNewestFirst() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr"),
            Row(
                id: 2,
                sender: "facetime@example.com",
                created: thirdDate,
                duration: 12.5,
                isRead: true,
                fileType: "m4a"
            ),
            Row(id: 3, sender: "+15550102", created: secondDate, fileType: "MOV"),
        ])

        let voicemails = try store.fetch(VoicemailMessage.FetchRequest(limit: 30))

        XCTAssertEqual(voicemails.map(\.id), [2, 3, 1])
        XCTAssertEqual(voicemails[0].sender, "facetime@example.com")
        XCTAssertEqual(voicemails[0].date, Date(timeIntervalSinceReferenceDate: thirdDate))
        XCTAssertEqual(voicemails[0].duration, 12.5)
        XCTAssertEqual(voicemails[0].isRead, true)
        XCTAssertEqual(voicemails[0].kind, .faceTimeAudio)
        XCTAssertEqual(voicemails[0].hasTranscript, false)
        XCTAssertEqual(voicemails[1].kind, .faceTimeVideo)
        XCTAssertEqual(voicemails[2].kind, .carrierVoicemail)
    }

    func testFetchFiltersBySenderTypeAndDate() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr"),
            Row(id: 2, sender: "+15550101", created: secondDate, fileType: "amr"),
            Row(id: 3, sender: "facetime@example.com", created: thirdDate, fileType: "m4a"),
        ])

        var request = VoicemailMessage.FetchRequest(limit: 30)
        request.sender = "5550101"
        XCTAssertEqual(try store.fetch(request).map(\.id), [2, 1])

        request = VoicemailMessage.FetchRequest(limit: 30)
        request.kind = .faceTimeAudio
        XCTAssertEqual(try store.fetch(request).map(\.id), [3])

        request = VoicemailMessage.FetchRequest(limit: 30)
        request.startDate = Date(timeIntervalSinceReferenceDate: firstDate)
        request.endDate = Date(timeIntervalSinceReferenceDate: thirdDate)
        XCTAssertEqual(try store.fetch(request).map(\.id), [2, 1])

        request = VoicemailMessage.FetchRequest(limit: 2)
        XCTAssertEqual(try store.fetch(request).map(\.id), [3, 2])
    }

    func testFetchExcludesDeletedMessages() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr"),
            Row(id: 2, sender: "+15550102", created: secondDate, fileType: "amr", deleted: secondDate),
        ])

        let voicemails = try store.fetch(VoicemailMessage.FetchRequest(limit: 30))

        XCTAssertEqual(voicemails.map(\.id), [1])
    }

    func testFetchSenderFilterMatchesLiteralWildcards() throws {
        try makeStore([
            Row(id: 1, sender: "a_b@example.com", created: firstDate, fileType: "amr"),
            Row(id: 2, sender: "axb@example.com", created: secondDate, fileType: "amr"),
            Row(id: 3, sender: "100%.example.com", created: thirdDate, fileType: "amr"),
        ])

        var request = VoicemailMessage.FetchRequest(limit: 30)
        request.sender = "_"
        XCTAssertEqual(try store.fetch(request).map(\.id), [1])

        request.sender = "%"
        XCTAssertEqual(try store.fetch(request).map(\.id), [3])
    }

    // MARK: - Messages and Transcripts

    func testMessageReturnsRowByID() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr", recordUUID: testUUID(1))
        ])

        let message = try XCTUnwrap(store.message(id: 1))
        XCTAssertEqual(message.sender, "+15550101")
        XCTAssertEqual(message.kind, .carrierVoicemail)
        XCTAssertNil(try store.message(id: 2))
    }

    func testTranscriptDecodesCarrierShape() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr", transcript: carrierTranscript())
        ])

        let transcript = try XCTUnwrap(store.transcript(id: 1))
        XCTAssertEqual(transcript.text, "Hello, leave a message")
        XCTAssertEqual(transcript.confidence, 0.85)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "Hello")
        XCTAssertEqual(transcript.segments[0].confidence, 0.9)
        XCTAssertEqual(transcript.segments[1].text, "leave a message")
    }

    func testTranscriptDecodesFaceTimeShape() throws {
        try makeStore([
            Row(
                id: 1,
                sender: "facetime@example.com",
                created: firstDate,
                fileType: "m4a",
                transcript: faceTimeTranscript()
            )
        ])

        let transcript = try XCTUnwrap(store.transcript(id: 1))
        XCTAssertEqual(transcript.text, "First sentence Second sentence")
        XCTAssertNil(transcript.confidence)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "First sentence")
        XCTAssertEqual(transcript.segments[1].confidence, 0.6)
    }

    func testTranscriptIsNilWithoutBlob() throws {
        try makeStore([
            Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr")
        ])

        XCTAssertNil(try store.transcript(id: 1))
    }

    // MARK: - Audio

    func testAudioResolvesByRecordUUID() throws {
        let row = Row(id: 1, sender: "+15550101", created: firstDate, fileType: "amr", recordUUID: testUUID(1))
        try makeStore([row])
        try writeAudio(for: row, contents: "carrier audio")

        let message = try XCTUnwrap(store.message(id: 1))
        XCTAssertEqual(message.hasAudio, true)
        XCTAssertEqual(store.audioMimeType(for: message), "audio/amr")
        let data = try XCTUnwrap(try store.audioData(for: message))
        XCTAssertEqual(String(data: data, encoding: .utf8), "carrier audio")
    }

    func testAudioHandlesOtherTypesAndMissingFiles() throws {
        let m4aRow = Row(
            id: 1,
            sender: "facetime@example.com",
            created: firstDate,
            fileType: "m4a",
            recordUUID: testUUID(1)
        )
        let movRow = Row(id: 2, sender: "+15550102", created: secondDate, fileType: "MOV", recordUUID: testUUID(2))
        let missingRow = Row(id: 3, sender: "+15550103", created: thirdDate, fileType: "amr", recordUUID: testUUID(3))
        try makeStore([m4aRow, movRow, missingRow])
        try writeAudio(for: m4aRow)
        try writeAudio(for: movRow)

        let m4aMessage = try XCTUnwrap(store.message(id: 1))
        XCTAssertEqual(store.audioMimeType(for: m4aMessage), "audio/mp4")
        XCTAssertEqual(m4aMessage.hasAudio, true)

        let movMessage = try XCTUnwrap(store.message(id: 2))
        XCTAssertEqual(movMessage.hasAudio, false)
        XCTAssertNil(store.audioMimeType(for: movMessage))
        XCTAssertNil(try store.audioData(for: movMessage))

        let missingMessage = try XCTUnwrap(store.message(id: 3))
        XCTAssertEqual(missingMessage.hasAudio, false)
        XCTAssertNil(try store.audioData(for: missingMessage))
    }

    // MARK: - Helpers

    /// A fixed UUID synthesized for tests, distinct per index.
    private func testUUID(_ index: Int) -> UUID {
        let pattern = "00000000-0000-0000-0000-00000000000X"
        let string = pattern.replacingOccurrences(of: "X", with: String(index))
        return UUID(uuidString: string)!
    }
}

/// The copy-on-bind destructor for `sqlite3_bind_` calls.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
