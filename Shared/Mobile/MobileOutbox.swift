import Foundation

/// Changes that iMCP on iOS has collected but the Mac hasn't stored yet,
/// and the sync state, such as HealthKit anchors, that produced them.
///
/// The outbox lives in the app's own Application Support directory, not the App Group container.
/// Records and the state that follows them are written in one transaction,
/// so an anchor never advances past changes that aren't queued.
/// The Mac pulls the oldest batch and acknowledges it after storing it;
/// until then, every pull returns the same batch.
actor MobileOutbox {
    struct Pull: Sendable {
        var batch: MobileBatch
        /// The Mac's cache is new or was deleted,
        /// so the queue and sync state were cleared and everything must be sent again.
        var reset: Bool
    }

    static let batchSize = 500

    /// A sync tried to write after the Mac's cache was reset.
    /// Its anchor predates the reset, so its changes must not be queued.
    struct Superseded: Error {}

    /// Counts resets. A sync reads it before its anchors
    /// and passes it to `enqueue`, which refuses writes from an older generation.
    var generation: Int {
        state("generation").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }

    private let database: MobileDatabase

    init(url: URL) throws {
        database = try MobileDatabase(path: url.path)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS batches (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                body BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS state (
                name TEXT PRIMARY KEY,
                value BLOB NOT NULL
            );
            """
        )
        try? (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
    }

    /// The outbox in the app's own Application Support directory.
    ///
    /// It used to live in the App Group container. iOS kills an app with 0xdead10cc
    /// when it is suspended while holding a SQLite lock on a file in a shared container,
    /// and background syncs can be suspended mid-write. Nothing else reads the outbox
    /// (the widget extension has no App Group), so it stays out of the shared container.
    static func shared() throws -> MobileOutbox {
        let url = try databaseURL(
            groupContainer: MobileAppGroup.containerURL(),
            supportDirectory: MobileAppGroup.supportDirectory()
        )
        migrateFromAppGroup(MobileAppGroup.containerURL(), to: url)
        // The old file stays the source of truth until the new one is complete.
        // If the migration has not finished, open the old outbox, so queued
        // records and anchors are never left behind.
        if let group = MobileAppGroup.containerURL() {
            let old = group.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: old.path) {
                return try MobileOutbox(url: old)
            }
        }
        return try MobileOutbox(url: url)
    }

    static let fileName = "outbox.sqlite"

    /// Where the database lives. The App Group container is never used.
    static func databaseURL(groupContainer: URL?, supportDirectory: URL) throws -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    /// The outbox's sidecar files, in the order they are copied.
    private static let sidecars = ["-wal", "-shm"]

    /// Moves an outbox that an earlier build left in the App Group container,
    /// so queued batches and HealthKit anchors survive and nothing is sent twice.
    ///
    /// The old file is the source of truth until the new one is complete. Each
    /// file is copied, not moved, and the old files are removed only after every
    /// copy has the same size as its source. A failed checkpoint or a failed copy
    /// leaves the old outbox in place, so the next launch tries again.
    static func migrateFromAppGroup(_ group: URL?, to url: URL) {
        let manager = FileManager.default
        guard let group else { return }
        let old = group.appendingPathComponent(fileName)
        guard old.standardizedFileURL != url.standardizedFileURL,
            manager.fileExists(atPath: old.path)
        else { return }

        // Fold the write-ahead log into the database before copying. If the
        // database can't be opened or the checkpoint fails, leave the old
        // outbox alone rather than copy a database whose recent commits are
        // only in the log.
        guard let database = try? MobileDatabase(path: old.path) else { return }
        do {
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        } catch {
            database.close()
            return
        }
        database.close()

        // Copy every file that exists. A partial copy is harmless: the old
        // files stay, and the next launch copies over them.
        for suffix in [""] + sidecars {
            let source = URL(fileURLWithPath: old.path + suffix)
            let destination = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            do {
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: source, to: destination)
            } catch {
                return
            }
        }

        // Remove the old files only when every copy matches its source.
        for suffix in [""] + sidecars {
            let source = URL(fileURLWithPath: old.path + suffix)
            let destination = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let destinationSize =
                (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let sourceSize, sourceSize == destinationSize else { return }
        }
        for suffix in [""] + sidecars {
            let source = URL(fileURLWithPath: old.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.removeItem(at: source)
        }
    }

    private struct Body: Codable {
        var syncedAt: [String: Date]
        var records: [MobileRecord]
        var replacing: [MobileKind]
    }

    // MARK: - Writing

    /// Queues records, split into batches of at most `batchSize`,
    /// and saves `state` in the same transaction.
    /// A nil state value removes that entry.
    func enqueue(
        _ records: [MobileRecord],
        syncedAt: [MobileDomain: Date],
        replacing: [MobileKind] = [],
        state: [String: Data?] = [:],
        generation: Int? = nil
    ) throws {
        let dates = Dictionary(uniqueKeysWithValues: syncedAt.map { ($0.key.rawValue, $0.value) })
        var chunks = stride(from: 0, to: records.count, by: Self.batchSize).map {
            Array(records[$0 ..< min($0 + Self.batchSize, records.count)])
        }
        if chunks.isEmpty, !dates.isEmpty || !replacing.isEmpty { chunks = [[]] }
        try database.transaction {
            // An expired background task cancels the sync; roll back instead of writing.
            try Task.checkCancellation()
            if let generation, generation != self.generation { throw Superseded() }
            for (index, chunk) in chunks.enumerated() {
                let last = index == chunks.count - 1
                let body = Body(
                    // Mark data as synced only when its last part arrives.
                    syncedAt: last ? dates : [:],
                    records: chunk,
                    replacing: index == 0 ? replacing : []
                )
                try database.run("INSERT INTO batches (body) VALUES (?)", [.blob(MobileCoding.encoder.encode(body))])
            }
            for (name, value) in state {
                try write(name, value)
            }
        }
    }

    func setState(_ name: String, _ value: Data?, generation: Int? = nil) throws {
        if let generation, generation != self.generation { throw Superseded() }
        try write(name, value)
    }

    private func write(_ name: String, _ value: Data?) throws {
        if let value {
            try database.run("INSERT OR REPLACE INTO state (name, value) VALUES (?, ?)", [.text(name), .blob(value)])
        } else {
            try database.run("DELETE FROM state WHERE name = ?", [.text(name)])
        }
    }

    /// Clears the queue and all sync state, as when the phone unpairs.
    func deleteAll() throws {
        let next = generation + 1
        try database.transaction {
            try database.run("DELETE FROM batches")
            try database.run("DELETE FROM state")
            try write("generation", Data(String(next).utf8))
        }
    }

    // MARK: - Reading

    func state(_ name: String) -> Data? {
        var value: Data?
        try? database.run("SELECT value FROM state WHERE name = ?", [.text(name)]) { row in value = row.blob(0) }
        return value
    }

    var pendingCount: Int {
        var count = 0
        try? database.run("SELECT count(*) FROM batches") { row in count = Int(row.int(0) ?? 0) }
        return count
    }

    /// The oldest queued batch, or an empty batch with sequence 0.
    func pull(cacheID: String) throws -> Pull {
        if state("cache") != Data(cacheID.utf8) {
            let next = generation + 1
            try database.transaction {
                try database.run("DELETE FROM batches")
                try database.run("DELETE FROM state")
                try write("cache", Data(cacheID.utf8))
                try write("generation", Data(String(next).utf8))
            }
            return Pull(batch: MobileBatch(sequence: 0, syncedAt: [:], records: []), reset: true)
        }
        var found: (Int64, Data)?
        try database.run("SELECT sequence, body FROM batches ORDER BY sequence LIMIT 1") { row in
            found = (row.int(0) ?? 0, row.blob(1) ?? Data())
        }
        guard let (sequence, data) = found else {
            return Pull(batch: MobileBatch(sequence: 0, syncedAt: [:], records: []), reset: false)
        }
        let body = try MobileCoding.decoder.decode(Body.self, from: data)
        return Pull(
            batch: MobileBatch(
                sequence: sequence,
                syncedAt: body.syncedAt,
                records: body.records,
                replacing: body.replacing,
                hasMore: pendingCount > 1
            ),
            reset: false
        )
    }

    /// Drops the batches up to and including `sequence`, which the Mac has stored.
    func ack(_ sequence: Int64) throws {
        try database.run("DELETE FROM batches WHERE sequence <= ?", [.int(sequence)])
    }
}

/// The container that iMCP on iOS shares with its extensions. It holds preferences only; databases stay out of it.
enum MobileAppGroup {
    /// The group ID from the `iMCPAppGroup` Info.plist key,
    /// which the build sets from the iOS app's bundle ID.
    static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "iMCPAppGroup") as? String
    }

    static func containerURL() -> URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static func supportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static var defaults: UserDefaults {
        identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
