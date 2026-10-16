import Foundation
import SQLite3

/// A read-only view of the voicemail store kept by the Phone app on macOS 26 and later.
///
/// Carrier and FaceTime voicemails sync to the Mac through the `facetimemessagestored`
/// daemon into a Core Data SQLite store inside the FaceTime group container. Message
/// audio lives in an `Assets` tree next to the database, addressed by each record's
/// UUID. The schema is private to the daemon; this store reads only the columns it
/// needs, tolerates the absence of the ones it can do without, and never writes.
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
            resolveAsset(of: &messages[index])
        }
        return messages
    }

    func message(id: Int) throws -> VoicemailMessage? {
        guard var message = try read({ try $0.message(id: id) }) else { return nil }
        resolveAsset(of: &message)
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
    ///
    /// The daemon writes the extension in either case (`MOV` and `mov` both occur).
    /// Audio-only `.mov` messages carry AAC audio in a QuickTime container,
    /// which `audio/mp4` players handle; video messages have no audio-only form.
    func audioMimeType(for message: VoicemailMessage) -> String? {
        guard message.kind != .faceTimeVideo else { return nil }
        switch message.fileType?.lowercased() {
        case "amr": return "audio/amr"
        case "m4a", "mov": return "audio/mp4"
        default: return nil
        }
    }

    /// Sets whether the message's audio is playable, and fills in a missing duration
    /// from the asset: the store records a duration of zero for some messages.
    private func resolveAsset(of message: inout VoicemailMessage) {
        let url = audioURL(for: message)
        message.hasAudio = url != nil && audioMimeType(for: message) != nil

        if message.duration <= 0,
            let url,
            ["m4a", "mov"].contains(message.fileType?.lowercased()),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let duration = QuickTimeMovie.duration(of: data)
        {
            message.duration = duration
        }
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

/// A row of the `ZSTOREDMESSAGE` table: one voicemail or FaceTime message.
struct VoicemailMessage {
    /// Where the message came from and what it holds.
    ///
    /// The provider separates the two sources: carrier voicemails come from
    /// `com.apple.coretelephony` whatever their file format (`amr`, `m4a`, or `MOV`),
    /// and FaceTime messages from the FaceTime call provider. Among FaceTime
    /// messages, a message type of 2 marks video.
    enum Kind: String {
        case carrierVoicemail
        case faceTimeAudio
        case faceTimeVideo

        /// The SQL predicate that selects rows of this kind.
        fileprivate var predicate: String {
            switch self {
            case .carrierVoicemail:
                return "ZPROVIDER = '\(carrierProvider)'"
            case .faceTimeAudio:
                return "ZPROVIDER LIKE '%\(faceTimeProviderSuffix)' AND ZMESSAGETYPE IS NOT 2"
            case .faceTimeVideo:
                return "ZPROVIDER LIKE '%\(faceTimeProviderSuffix)' AND ZMESSAGETYPE = 2"
            }
        }

        /// The kind of a row, or nil when its provider is missing or unfamiliar.
        fileprivate init?(provider: String?, messageType: Int?) {
            guard let provider else { return nil }
            if provider == carrierProvider {
                self = .carrierVoicemail
            } else if provider.lowercased().hasSuffix(faceTimeProviderSuffix.lowercased()) {
                self = messageType == 2 ? .faceTimeVideo : .faceTimeAudio
            } else {
                return nil
            }
        }
    }

    /// The Phone app's voicemail mailbox that holds the message.
    enum Mailbox: Int, CaseIterable {
        case inbox = 0
        case blocked = 1
        case deleted = 2

        var name: String {
            switch self {
            case .inbox: return "inbox"
            case .blocked: return "blocked"
            case .deleted: return "deleted"
            }
        }

        init?(name: String) {
            guard let mailbox = Self.allCases.first(where: { $0.name == name }) else {
                return nil
            }
            self = mailbox
        }
    }

    let id: Int
    let sender: String?
    /// When the message was left, as seconds since the Core Data reference date (2001-01-01).
    let date: Date
    /// Length in seconds; the store filling in a missing value from the asset.
    var duration: TimeInterval
    let isRead: Bool
    let fileType: String?
    let recordUUID: Data
    let hasTranscript: Bool
    /// The message's kind, or nil when the store does not say.
    let kind: Kind?
    /// The message's mailbox, or nil when the store does not say.
    let mailbox: Mailbox?
    /// Whether the message's audio exists in the `Assets` tree in a format clients can play.
    var hasAudio = false

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

        func integer(_ column: Int32) -> Int? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, column))
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
        kind = Kind(provider: text(8), messageType: integer(9))
        mailbox = integer(10).flatMap(Mailbox.init(rawValue:))
    }
}

extension VoicemailMessage {
    struct FetchRequest {
        /// Sender (phone number or address) to match (partial, case-insensitive).
        /// A phone number also matches by its digits alone, whatever its formatting.
        var sender: String?
        /// Start of the date range (inclusive).
        var startDate: Date?
        /// End of the date range (exclusive).
        var endDate: Date?
        var kind: Kind?
        /// The mailbox to read, or nil for all of them.
        var mailbox: Mailbox? = .inbox
        var limit: Int

        /// The SQL and its bound values, in placeholder order,
        /// for a store with the given columns.
        fileprivate func statement(
            columns: Set<String>
        ) throws -> (sql: String, bindings: [SQLiteValue]) {
            var conditions = ["ZDATEDELETED IS NULL"]
            var bindings: [SQLiteValue] = []

            if let sender {
                var matches = ["ZFROM LIKE ? ESCAPE '\\'"]
                bindings.append(.text("%" + escapingLikeWildcards(sender) + "%"))
                if let digits = phoneNumberDigits(sender) {
                    matches.append("\(digitsOnly("ZFROM")) LIKE ?")
                    bindings.append(.text("%" + digits + "%"))
                }
                conditions.append("(" + matches.joined(separator: " OR ") + ")")
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
                guard columns.contains("ZPROVIDER"), columns.contains("ZMESSAGETYPE") else {
                    throw VoicemailStoreError.unsupportedFilter("type")
                }
                conditions.append(kind.predicate)
            }
            // A store without mailboxes keeps every message in one place.
            if let mailbox, columns.contains("ZMAILBOXTYPE") {
                conditions.append("ZMAILBOXTYPE = ?")
                bindings.append(.int(mailbox.rawValue))
            }

            bindings.append(.int(limit))
            let sql = """
                SELECT \(selectedColumns(in: columns))
                FROM ZSTOREDMESSAGE
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY ZDATECREATED DESC
                LIMIT ?
                """
            return (sql, bindings)
        }

        /// Escapes SQL LIKE wildcards, for use with the ESCAPE clause, so the
        /// sender filter matches literal text: a_b@example.com must not match
        /// axb@example.com.
        private func escapingLikeWildcards(_ text: String) -> String {
            var escaped = ""
            for character in text {
                switch character {
                case "\\", "%", "_":
                    escaped.append("\\")
                    escaped.append(character)
                default:
                    escaped.append(character)
                }
            }
            return escaped
        }

        /// The digits of a sender filter that reads as a phone number:
        /// at least three digits, and nothing but digits and phone formatting.
        private func phoneNumberDigits(_ text: String) -> String? {
            let digits = text.filter { $0.isASCII && $0.isNumber }
            let formatting: Set<Character> = ["+", "-", " ", "(", ")", "."]
            guard digits.count >= 3,
                text.allSatisfy({ ($0.isASCII && $0.isNumber) || formatting.contains($0) })
            else { return nil }
            return digits
        }

        /// A SQL expression for a column's value with phone formatting removed.
        private func digitsOnly(_ column: String) -> String {
            ["+", "-", " ", "(", ")", "."].reduce(column) { expression, character in
                "REPLACE(\(expression), '\(character)', '')"
            }
        }
    }
}

enum VoicemailStoreError: LocalizedError {
    case unsupportedFilter(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFilter(let name):
            return "This Mac's voicemail store does not record the information the \(name) filter needs"
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

// MARK: -

/// Reads the movie header of QuickTime and MPEG-4 files.
///
/// The daemon writes `.mov` and `.m4a` messages; both use the same atom structure.
enum QuickTimeMovie {
    /// The movie's duration in seconds, from its `mvhd` atom,
    /// or nil when the data does not parse as a movie with a duration.
    static func duration(of data: Data) -> TimeInterval? {
        for movie in childPayloads(ofType: "moov", in: data, within: 0 ..< data.count) {
            for header in childPayloads(ofType: "mvhd", in: data, within: movie) {
                // Version 0 stores 32-bit times; version 1 stores 64-bit
                // creation, modification, and duration values.
                guard header.count >= 1 else { continue }
                let isVersion1 = data[header.lowerBound] == 1
                let timescaleOffset = header.lowerBound + (isVersion1 ? 20 : 12)
                let durationLength = isVersion1 ? 8 : 4
                guard
                    let timescale = integer(in: data, at: timescaleOffset, length: 4, within: header),
                    let duration = integer(
                        in: data,
                        at: timescaleOffset + 4,
                        length: durationLength,
                        within: header
                    ),
                    timescale > 0
                else { continue }
                return TimeInterval(duration) / TimeInterval(timescale)
            }
        }
        return nil
    }

    /// A big-endian unsigned integer, when it lies within the bounds.
    private static func integer(
        in data: Data,
        at offset: Int,
        length: Int,
        within bounds: Range<Int>
    ) -> UInt64? {
        guard offset >= bounds.lowerBound, length <= bounds.upperBound - offset else {
            return nil
        }
        return data[offset ..< (offset + length)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The payload ranges of the immediate child atoms of the given type,
    /// within a container atom's payload — or the whole file, at its root.
    private static func childPayloads(
        ofType type: String,
        in data: Data,
        within bounds: Range<Int>
    ) -> [Range<Int>] {
        var payloads: [Range<Int>] = []
        var offset = bounds.lowerBound
        while offset + 8 <= bounds.upperBound {
            let header = data.subdata(in: offset ..< (offset + 8))
            var size = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            var headerSize = 8
            if size == 1 {
                // A size of 1 marks an extended header whose 64-bit size
                // follows the atom type.
                guard offset + 16 <= bounds.upperBound else { break }
                let extended = data.subdata(in: (offset + 8) ..< (offset + 16))
                    .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard let exact = Int(exactly: extended) else { break }
                size = exact == 0 ? bounds.upperBound - offset : exact  // To end of container.
                headerSize = 16
            } else if size == 0 {
                size = bounds.upperBound - offset  // To end of container.
            }
            // Compare against the remaining bytes — a malformed size up to
            // `Int.max` would overflow an `offset + size` addition and trap.
            guard size >= headerSize, size <= bounds.upperBound - offset else { break }
            if header.suffix(4) == Data(type.utf8) {
                payloads.append((offset + headerSize) ..< (offset + size))
            }
            offset += size
        }
        return payloads
    }
}

/// The provider of carrier voicemails.
private let carrierProvider = "com.apple.coretelephony"

/// The end of the FaceTime call provider's identifier,
/// `com.apple.telephonyutilities.callservicesd.FaceTimeProvider`.
private let faceTimeProviderSuffix = ".FaceTimeProvider"

/// Columns the store needs, in selection order.
private let requiredColumns = [
    "Z_PK", "ZFROM", "ZDATECREATED", "ZDURATION", "ZISREAD", "ZFILETYPE", "ZRECORDUUID",
    "ZTRANSCRIPT IS NOT NULL",
]

/// Columns the store reads when present, in selection order after the required ones.
/// Without them, kinds and mailboxes read as unknown.
private let optionalColumns = ["ZPROVIDER", "ZMESSAGETYPE", "ZMAILBOXTYPE"]

/// The select list for a store with the given columns,
/// with NULL in place of each optional column it lacks.
private func selectedColumns(in columns: Set<String>) -> String {
    let optional = optionalColumns.map { columns.contains($0) ? $0 : "NULL" }
    return (requiredColumns + optional).joined(separator: ", ")
}

/// A read-only connection to the voicemail store.
private final class VoicemailStoreDatabase {
    private let connection: OpaquePointer

    /// The names of the columns of `ZSTOREDMESSAGE`.
    private lazy var columns: Set<String> = {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM pragma_table_info('ZSTOREDMESSAGE')"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: name))
            }
        }
        return names
    }()

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
        let (sql, bindings) = try request.statement(columns: columns)

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
        let sql = """
            SELECT \(selectedColumns(in: columns))
            FROM ZSTOREDMESSAGE
            WHERE Z_PK = ? AND ZDATEDELETED IS NULL
            """
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
            sqlite3_bind_int64(statement, index, Int64(int))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
