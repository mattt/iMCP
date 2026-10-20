import CryptoKit
import Foundation
import Security

/// The Mac's copy of the data that iMCP sends from a paired iPhone or iPad.
///
/// Records live in a SQLite database in Application Support.
/// Payloads are sealed with AES-GCM under a key kept in the Keychain,
/// with each record's kind and ID as authenticated data,
/// so the file alone doesn't reveal health or finance data
/// and a payload can't be moved to another row.
/// Kinds, IDs, query keys, and dates stay in plaintext so that queries can filter on them.
actor MobileCache {
    struct Row: Sendable {
        let id: String
        let key: String?
        let start: Date?
        let end: Date?
        let payload: Value
    }

    private let url: URL
    private let key: SymmetricKey
    private var database: MobileDatabase?

    init(url: URL, key: SymmetricKey) throws {
        self.url = url
        self.key = key
        database = try Self.open(url)
    }

    /// The cache in Application Support, with its key from the Keychain.
    static func standard() throws -> MobileCache {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Mobile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try MobileCache(
            url: directory.appendingPathComponent("cache.sqlite"),
            key: MobileKeychain.cacheKey()
        )
    }

    private static func open(_ url: URL) throws -> MobileDatabase {
        let database = try MobileDatabase(path: url.path)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS records (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                key TEXT,
                start REAL,
                end REAL,
                payload BLOB NOT NULL,
                PRIMARY KEY (kind, id)
            );
            CREATE INDEX IF NOT EXISTS records_by_key ON records (kind, key, start);
            CREATE TABLE IF NOT EXISTS sync_state (
                domain TEXT PRIMARY KEY,
                synced_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (
                name TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            INSERT OR IGNORE INTO meta (name, value) VALUES ('cache_id', lower(hex(randomblob(16))));
            """
        )
        return database
    }

    private func db() throws -> MobileDatabase {
        if let database { return database }
        let database = try Self.open(url)
        self.database = database
        return database
    }

    func close() {
        database?.close()
        database = nil
    }

    // MARK: - Writing

    /// Applies a batch in one transaction.
    /// Upserts replace earlier versions and deletions of unknown IDs do nothing,
    /// so applying the same batch again doesn't change the cache.
    func apply(_ batch: MobileBatch) throws {
        let database = try db()
        try database.transaction {
            for kind in batch.replacing {
                try database.run("DELETE FROM records WHERE kind = ?", [.text(kind.rawValue)])
            }
            for record in batch.records {
                if let payload = record.payload {
                    try database.run(
                        "INSERT OR REPLACE INTO records (kind, id, key, start, end, payload) VALUES (?, ?, ?, ?, ?, ?)",
                        [
                            .text(record.kind.rawValue), .text(record.id), .init(record.key), .init(record.start),
                            .init(record.end), .blob(try seal(payload, kind: record.kind, id: record.id)),
                        ]
                    )
                } else {
                    try database.run(
                        "DELETE FROM records WHERE kind = ? AND id = ?",
                        [.text(record.kind.rawValue), .text(record.id)]
                    )
                }
            }
            for (domain, date) in batch.syncedAt where MobileDomain(rawValue: domain) != nil {
                try database.run(
                    """
                    INSERT INTO sync_state (domain, synced_at) VALUES (?, ?)
                    ON CONFLICT (domain) DO UPDATE SET synced_at = max(synced_at, excluded.synced_at)
                    """,
                    [.text(domain), .double(date.timeIntervalSince1970)]
                )
            }
        }
    }

    /// Identifies this copy of the cache.
    /// It changes when the cache is deleted,
    /// which tells the phone to send all of its data again.
    func cacheID() throws -> String {
        var id = ""
        try db().run("SELECT value FROM meta WHERE name = 'cache_id'") { row in id = row.text(0) ?? "" }
        return id
    }

    /// The last status the phone reported, such as why Finance is unavailable.
    func phoneStatus() -> Value? {
        var status: Value?
        try? db().run("SELECT value FROM meta WHERE name = 'phone_status'") { row in
            status = row.text(0).flatMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) }
        }
        return status
    }

    func setPhoneStatus(_ status: Value) throws {
        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        try db().run("INSERT OR REPLACE INTO meta (name, value) VALUES ('phone_status', ?)", [.text(text)])
    }

    /// Removes every record and all sync state.
    func deleteAll() throws {
        let database = try db()
        try database.transaction {
            try database.run("DELETE FROM records")
            try database.run("DELETE FROM sync_state")
            try database.run("UPDATE meta SET value = lower(hex(randomblob(16))) WHERE name = 'cache_id'")
            try database.run("DELETE FROM meta WHERE name = 'phone_status'")
        }
        try database.execute("VACUUM")
    }

    // MARK: - Reading

    /// Records of one kind, newest first unless `ascending`,
    /// that overlap the date range when one is given.
    /// Ranges are half-open: an interval that ends when the range starts doesn't overlap it,
    /// but a point record at the start does.
    func records(
        _ kind: MobileKind,
        key: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        limit: Int? = nil,
        ascending: Bool = false
    ) throws -> [Row] {
        var sql = "SELECT id, key, start, end, payload FROM records WHERE kind = ?"
        var bindings: [MobileDatabase.Binding] = [.text(kind.rawValue)]
        if let key {
            sql += " AND key = ?"
            bindings.append(.text(key))
        }
        if let start {
            sql += " AND (end > ? OR start >= ?)"
            bindings += [.init(start), .init(start)]
        }
        if let end {
            sql += " AND start < ?"
            bindings.append(.init(end))
        }
        sql += " ORDER BY start \(ascending ? "ASC" : "DESC"), id \(ascending ? "ASC" : "DESC")"
        if let limit {
            sql += " LIMIT ?"
            bindings.append(.int(Int64(limit)))
        }
        var rows: [Row] = []
        try db().run(sql, bindings) { row in
            let id = row.text(0) ?? ""
            let data = try self.open(row.blob(4) ?? Data(), kind: kind, id: id)
            rows.append(
                Row(
                    id: id,
                    key: row.text(1),
                    start: row.double(2).map(Date.init(timeIntervalSince1970:)),
                    end: row.double(3).map(Date.init(timeIntervalSince1970:)),
                    payload: try JSONDecoder().decode(Value.self, from: data)
                )
            )
        }
        return rows
    }

    func syncedAt(_ domain: MobileDomain) -> Date? {
        var date: Date?
        try? db().run("SELECT synced_at FROM sync_state WHERE domain = ?", [.text(domain.rawValue)]) { row in
            date = row.double(0).map(Date.init(timeIntervalSince1970:))
        }
        return date
    }

    func count(_ kind: MobileKind) -> Int {
        var count = 0
        try? db().run("SELECT count(*) FROM records WHERE kind = ?", [.text(kind.rawValue)]) { row in
            count = Int(row.int(0) ?? 0)
        }
        return count
    }

    // MARK: - Encryption

    private func seal(_ payload: Data, kind: MobileKind, id: String) throws -> Data {
        let box = try AES.GCM.seal(payload, using: key, authenticating: Data("\(kind.rawValue)|\(id)".utf8))
        guard let combined = box.combined else { throw MobileError("Can't encrypt a cached record.") }
        return combined
    }

    private func open(_ sealed: Data, kind: MobileKind, id: String) throws -> Data {
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed),
                using: key,
                authenticating: Data("\(kind.rawValue)|\(id)".utf8)
            )
        } catch {
            throw MobileError(
                "The cached iPhone and iPad data can't be decrypted with this Mac's key. Delete it in Settings > iPhone & iPad, then let the device sync again."
            )
        }
    }
}

/// Secrets that the Mac keeps for paired devices:
/// the cache key and the key for each paired iPhone or iPad.
enum MobileKeychain {
    private static let service = "co.dododo.iMCP.Mobile"

    static func cacheKey() throws -> SymmetricKey {
        if let data = try read("cache-key") { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try write("cache-key", key.withUnsafeBytes { Data($0) })
        return key
    }

    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        return result as? Data
    }

    static func write(_ account: String, _ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> MobileError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return MobileError("The Keychain refused a pairing secret: \(message)")
    }
}
