import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A SQLite connection for the mobile services' own stores:
/// the Mac's cache and the phone's outbox.
/// It isn't thread-safe; each store confines it to one actor.
final class MobileDatabase {
    enum Binding {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func text(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            handle = nil
            throw Failure(message: "Can't open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw Failure(message: "The database is closed.") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    /// Runs a statement and calls `each` for every row it returns.
    func run(_ sql: String, _ bindings: [Binding] = [], each: ((Row) throws -> Void)? = nil) throws {
        guard let handle else { throw Failure(message: "The database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .null: result = sqlite3_bind_null(statement, index)
            case .int(let value): result = sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1),
                        Int32(value.count),
                        transient
                    )
                }
            }
            guard result == SQLITE_OK else { throw error() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try each?(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    /// Runs `body` in a transaction that rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func error() -> Failure {
        Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The database is closed.")
    }
}

extension MobileDatabase.Binding {
    init(_ date: Date?) { self = date.map { .double($0.timeIntervalSince1970) } ?? .null }
    init(_ text: String?) { self = text.map { .text($0) } ?? .null }
}
