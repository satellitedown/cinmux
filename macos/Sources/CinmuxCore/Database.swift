import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case text(String)
    case null

    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    /// Empty identifiers are stored as NULL (no folder).
    static func nullable(_ value: String) -> SQLValue { value.isEmpty ? .null : .text(value) }
}

struct SQLRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    /// NULL reads as the empty string, like QVariant::toString().
    func text(_ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }
}

/// A single SQLite connection, used from one thread at a time.
final class Database {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the state database"
            sqlite3_close_v2(handle)
            handle = nil
            throw CinmuxError.message(message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    private var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The state database is closed" }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var changes: Int { Int(sqlite3_changes(handle)) }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            let message = errorMessage
            sqlite3_finalize(statement)
            throw CinmuxError.message(message)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(prepared, index, number)
            case .text(let text): status = sqlite3_bind_text(prepared, index, text, -1, Database.transient)
            case .null: status = sqlite3_bind_null(prepared, index)
            }
            if status != SQLITE_OK {
                let message = errorMessage
                sqlite3_finalize(prepared)
                throw CinmuxError.message(message)
            }
        }
        return prepared
    }

    /// Runs a statement to completion, ignoring any rows it returns (e.g. PRAGMA results).
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try query(sql, values) { _ in }
    }

    func query(_ sql: String, _ values: [SQLValue] = [], row: (SQLRow) throws -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(SQLRow(statement: statement))
            case SQLITE_DONE: return
            default: throw CinmuxError.message(errorMessage)
            }
        }
    }

    func scalar(_ sql: String) throws -> Int64? {
        var result: Int64?
        try query(sql) { row in if result == nil { result = row.int(0) } }
        return result
    }

    /// BEGIN IMMEDIATE … COMMIT, rolling back when `body` or the commit fails.
    func immediateTransaction<T>(_ body: () throws -> T) throws -> T {
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
}
