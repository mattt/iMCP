import Foundation
import SQLite3

/// A read-only view of the voicemail store kept by the Phone app on macOS 26 and later.
///
/// Carrier and FaceTime voicemails sync to the Mac through the `facetimemessagestored`
/// daemon into a Core Data SQLite store inside the FaceTime group container. Message
/// audio lives in an `Assets` tree next to the database, addressed by each record's
/// UUID. The schema is private to the daemon; this store reads only the columns it
/// needs and never writes.
struct VoicemailStore {
    static let databaseFileName = "FaceTimeMessageStore-local.sqlitedb"

    /// Path of the `Data Store` folder holding the database and the `Assets` tree.
    let directoryPath: String

    var databasePath: String {
        directoryPath + "/" + VoicemailStore.databaseFileName
    }

    func fetch(_ request: VoicemailMessage.FetchRequest) throws -> [VoicemailMessage] {
        var messages = try read { try $0.fetch(request) }
        for index in messages.indices {
            messages[index].hasAudio = hasPlayableAudio(messages[index])
        }
        return messages
    }

    func message(id: Int) throws -> VoicemailMessage? {
        guard var message = try read({ try $0.message(id: id) }) else { return nil }
        message.hasAudio = hasPlayableAudio(message)
        return message
    }

    /// The transcript of the message, or nil when the store has none for it.
    func transcript(id: Int) throws -> VoicemailTranscript? {
        guard let data = try read({ try $0.transcriptData(id: id) }) else { return nil }
        return try VoicemailTranscriptDecoder.decode(data)
    }

    /// Location of the message's audio file in the `Assets` tree, when it exists on disk.
    func audioURL(for message: VoicemailMessage) -> URL? {
        guard let audioFileName = message.audioFileName else { return nil }
        let url = URL(fileURLWithPath: directoryPath).appendingPathComponent(audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The bytes of the message's audio, when it exists in a playable format.
    func audioData(for message: VoicemailMessage) throws -> Data? {
        guard audioMimeType(for: message) != nil, let url = audioURL(for: message) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    /// The MIME type of the message's audio, when it is a format clients can play.
    func audioMimeType(for message: VoicemailMessage) -> String? {
        switch message.fileType {
        case "amr": return "audio/amr"
        case "m4a": return "audio/mp4"
        default: return nil
        }
    }

    /// Whether the message's audio is available: an existing file in a playable format.
    private func hasPlayableAudio(_ message: VoicemailMessage) -> Bool {
        audioMimeType(for: message) != nil && audioURL(for: message) != nil
    }

    /// Reads the store live, honoring its write-ahead log.
    /// If SQLite cannot open the log's companion files, for example because they are
    /// absent and the folder is read-only, it reads the main file alone instead.
    private func read<T>(_ operation: (VoicemailStoreDatabase) throws -> T) throws -> T {
        do {
            return try operation(VoicemailStoreDatabase(path: databasePath, immutable: false))
        } catch is SQLiteError {
            return try operation(VoicemailStoreDatabase(path: databasePath, immutable: true))
        }
    }
}

// MARK: -

/// A row of the `ZSTOREDMESSAGE` table: one voicemail or FaceTime audio message.
struct VoicemailMessage {
    enum Kind: String {
        case carrierVoicemail
        case faceTimeAudio
        case faceTimeVideo

        /// The `ZFILETYPE` value rows of this kind carry.
        var fileType: String {
            switch self {
            case .carrierVoicemail: return "amr"
            case .faceTimeAudio: return "m4a"
            case .faceTimeVideo: return "MOV"
            }
        }

        /// The SQL predicate that selects messages of this kind.
        fileprivate var predicate: String {
            return "ZFILETYPE = '" + fileType + "'"
        }

        /// The kind matching a `ZFILETYPE` value, for the kinds the store defines.
        fileprivate init?(fileType: String?) {
            switch fileType {
            case "amr": self = .carrierVoicemail
            case "m4a": self = .faceTimeAudio
            case "MOV": self = .faceTimeVideo
            default: return nil
            }
        }
    }

    let id: Int
    let sender: String?
    /// When the message was left, as seconds since the Core Data reference date (2001-01-01).
    let date: Date
    let duration: TimeInterval
    let isRead: Bool
    let fileType: String?
    let recordUUID: Data
    let hasTranscript: Bool
    /// Whether the message's audio exists in the `Assets` tree in a format clients can play.
    var hasAudio = false

    var kind: Kind? {
        Kind(fileType: fileType)
    }

    /// Path of the audio file in the `Assets` tree, relative to the store's directory.
    var audioFileName: String? {
        guard let fileType, !fileType.isEmpty, let uuid = recordUUID.uuidString else { return nil }
        return "Assets/" + uuid.prefix(2) + "/" + uuid + "." + fileType
    }

    /// Reads the current row of a statement prepared with the store's column list.
    fileprivate init(_ statement: OpaquePointer?) {
        func text(_ column: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            let string = String(cString: cString)
            return string.isEmpty ? nil : string
        }

        func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            let byteCount = Int(sqlite3_column_bytes(statement, column))
            guard byteCount > 0 else { return Data() }
            return Data(bytes: bytes, count: byteCount)
        }

        id = Int(sqlite3_column_int64(statement, 0))
        sender = text(1)
        date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
        duration = sqlite3_column_double(statement, 3)
        isRead = sqlite3_column_int(statement, 4) == 1
        fileType = text(5)
        recordUUID = blob(6)
        hasTranscript = sqlite3_column_int(statement, 7) == 1
    }
}

extension VoicemailMessage {
    struct FetchRequest {
        /// Sender (phone number or address) to match (partial, case-insensitive).
        var sender: String?
        /// Start of the date range (inclusive).
        var startDate: Date?
        /// End of the date range (exclusive).
        var endDate: Date?
        var kind: Kind?
        var limit: Int

        /// The SQL and its bound values, in placeholder order.
        fileprivate var statement: (sql: String, bindings: [SQLiteValue]) {
            var conditions = ["ZDATEDELETED IS NULL"]
            var bindings: [SQLiteValue] = []

            if let sender {
                conditions.append("ZFROM LIKE ?")
                bindings.append(.text("%" + sender + "%"))
            }
            if let startDate {
                conditions.append("ZDATECREATED >= ?")
                bindings.append(.double(startDate.timeIntervalSinceReferenceDate))
            }
            if let endDate {
                conditions.append("ZDATECREATED < ?")
                bindings.append(.double(endDate.timeIntervalSinceReferenceDate))
            }
            if let kind {
                conditions.append(kind.predicate)
            }
            bindings.append(.int(limit))

            let sql = """
                SELECT \(voicemailColumns)
                FROM ZSTOREDMESSAGE
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY ZDATECREATED DESC
                LIMIT ?
                """
            return (sql, bindings)
        }
    }
}

// MARK: -

/// A voicemail transcript, as stored by the voicemail daemon.
struct VoicemailTranscript {
    struct Segment {
        let text: String
        let confidence: Double?
    }

    /// The flattened transcript text.
    let text: String
    /// Per-utterance segments, when the store provides them.
    let segments: [Segment]
    /// Overall confidence, when the store provides it.
    let confidence: Double?
}

/// Decodes the `NSKeyedArchiver` archives the voicemail daemon writes into `ZTRANSCRIPT`.
enum VoicemailTranscriptDecoder {
    static func decode(_ data: Data) throws -> VoicemailTranscript {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let archive = plist as? [String: Any],
            let objects = archive["$objects"] as? [Any],
            let top = archive["$top"] as? [String: Any],
            let rootReference = top["root"]
        else {
            throw DecodingError.malformedArchive
        }

        let root = resolve(rootReference, in: objects)

        // Carrier voicemails archive a transcript object with the flattened text
        // alongside per-segment detail.
        if let dictionary = root as? [String: Any],
            dictionary["transcriptionString"] != nil || dictionary["segments"] != nil
        {
            let segments = (dictionary["segments"] as? [Any] ?? []).compactMap {
                $0 as? [String: Any]
            }.map(Self.segment)
            let text =
                (dictionary["transcriptionString"] as? String)
                ?? segments.map(\.text).joined(separator: " ")
            return VoicemailTranscript(
                text: text,
                segments: segments,
                confidence: dictionary["confidence"] as? Double
            )
        }

        // FaceTime messages archive a bare array of segments.
        if let elements = root as? [Any] {
            let segments = elements.compactMap { $0 as? [String: Any] }.map(Self.segment)
            return VoicemailTranscript(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                confidence: nil
            )
        }

        throw DecodingError.malformedArchive
    }

    private static func segment(_ dictionary: [String: Any]) -> VoicemailTranscript.Segment {
        return VoicemailTranscript.Segment(
            text: dictionary["text"] as? String ?? "",
            confidence: dictionary["confidence"] as? Double
        )
    }

    /// Materializes a keyed-archive object graph, following `CFKeyedArchiverUID`
    /// references into the archive's `$objects` array.
    ///
    /// `PropertyListSerialization` hands those references back as opaque Core Foundation
    /// types. Their only public surface is the debug description,
    /// `<CFKeyedArchiverUID ...>{value = N}`, so the index is read from it.
    private static func resolve(_ object: Any, in objects: [Any]) -> Any {
        if let index = keyedArchiverUIDValue(of: object) {
            guard objects.indices.contains(index) else { return NSNull() }
            return resolve(objects[index], in: objects)
        }

        switch object {
        case let dictionary as [String: Any]:
            // A mutable-dictionary proxy in the archive: pair its keys with its values.
            if let keys = dictionary["NS.keys"] as? [Any],
                let values = dictionary["NS.objects"] as? [Any]
            {
                var pairs: [String: Any] = [:]
                for (key, value) in zip(keys, values) {
                    guard let key = resolve(key, in: objects) as? String else { continue }
                    pairs[key] = resolve(value, in: objects)
                }
                return pairs
            }
            // A mutable-array proxy in the archive: materialize its elements.
            if let elements = dictionary["NS.objects"] as? [Any] {
                return elements.map { resolve($0, in: objects) }
            }
            if dictionary["$classname"] != nil {
                return NSNull()  // A class description, not data.
            }
            var values: [String: Any] = [:]
            for (key, value) in dictionary where key != "$class" {
                values[key] = resolve(value, in: objects)
            }
            return values
        case let array as [Any]:
            return array.map { resolve($0, in: objects) }
        default:
            return object
        }
    }

    /// The `$objects` index a `CFKeyedArchiverUID` refers to, read from its description.
    private static func keyedArchiverUIDValue(of object: Any) -> Int? {
        let description = String(describing: object)
        guard description.hasPrefix("<CFKeyedArchiverUID"),
            let range = description.range(of: "value = ")
        else { return nil }
        return Int(description[range.upperBound...].prefix { $0.isNumber })
    }

    enum DecodingError: LocalizedError {
        case malformedArchive

        var errorDescription: String? {
            switch self {
            case .malformedArchive:
                return "The transcript archive is malformed"
            }
        }
    }
}

// MARK: -

fileprivate extension Data {
    /// The UUID string for the 16 raw bytes the store keeps in `ZRECORDUUID`,
    /// in the uppercase form the `Assets` tree uses for file names.
    var uuidString: String? {
        guard count == 16 else { return nil }
        let bytes = [UInt8](self)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        return uuid.uuidString
    }
}

/// The columns of `ZSTOREDMESSAGE` the store reads, in selection order.
private let voicemailColumns =
    "Z_PK, ZFROM, ZDATECREATED, ZDURATION, ZISREAD, ZFILETYPE, ZRECORDUUID, ZTRANSCRIPT IS NOT NULL"

/// A read-only connection to the voicemail store.
private final class VoicemailStoreDatabase {
    private let connection: OpaquePointer

    /// Opens the store read-only.
    /// With `immutable`, SQLite ignores the write-ahead log and never touches the `-wal`
    /// and `-shm` files, so records since the last checkpoint are not visible.
    init(path: String, immutable: Bool) throws {
        var filename = path
        var flags = SQLITE_OPEN_READONLY
        if immutable {
            var components = URLComponents()
            components.scheme = "file"
            components.path = path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else {
                throw SQLiteError(message: "cannot build a URI for \(path)")
            }
            filename = uri
            flags |= SQLITE_OPEN_URI
        }

        var connection: OpaquePointer?
        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(connection) }
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        self.connection = connection!
    }

    deinit {
        sqlite3_close(connection)
    }

    func fetch(_ request: VoicemailMessage.FetchRequest) throws -> [VoicemailMessage] {
        let (sql, bindings) = request.statement

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        var messages: [VoicemailMessage] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            messages.append(VoicemailMessage(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        return messages
    }

    func message(id: Int) throws -> VoicemailMessage? {
        var statement: OpaquePointer?
        let sql = "SELECT \(voicemailColumns) FROM ZSTOREDMESSAGE WHERE Z_PK = ? AND ZDATEDELETED IS NULL"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        SQLiteValue.int(id).bind(to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return VoicemailMessage(statement)
        case SQLITE_DONE:
            return nil
        case let result:
            throw SQLiteError(message: "stepping the statement failed with code \(result)")
        }
    }

    func transcriptData(id: Int) throws -> Data? {
        var statement: OpaquePointer?
        let sql = "SELECT ZTRANSCRIPT FROM ZSTOREDMESSAGE WHERE Z_PK = ? AND ZDATEDELETED IS NULL"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }

        SQLiteValue.int(id).bind(to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            guard byteCount > 0 else { return nil }
            return Data(bytes: bytes, count: byteCount)
        case SQLITE_DONE:
            return nil
        case let result:
            throw SQLiteError(message: "stepping the statement failed with code \(result)")
        }
    }
}

private struct SQLiteError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return "SQLite error: \(message)"
    }
}

/// A value bound to a `?` placeholder in a prepared statement.
private enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int)

    func bind(to statement: OpaquePointer?, at index: Int32) {
        switch self {
        case .text(let string):
            sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
        case .double(let double):
            sqlite3_bind_double(statement, index, double)
        case .int(let int):
            sqlite3_bind_int(statement, index, Int32(clamping: int))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
