import Foundation
import PicknickCore
import SQLite3

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection with a prepared-statement cache.
///
/// Not thread safe by design: it is confined to the actor that owns it, which
/// is cheaper and simpler than a connection pool for a workload that is one
/// writer and short bursts of reads.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw PicknickError.storeUnavailable(message)
        }

        // Busy timeout matters even for a single connection: an iOS process can
        // be resumed while a previous instance still holds the write lock.
        sqlite3_busy_timeout(handle, 3_000)

        try execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA temp_store = MEMORY;
            """
        )
    }

    deinit {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(handle)
    }

    func userVersion() throws -> Int32 {
        try query("PRAGMA user_version") { Int32($0.int(0)) }.first ?? 0
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Runs one or more statements with no bindings. Used for schema work.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw PicknickError.storeFailure(operation: "execute", message: message)
        }
    }

    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepared(sql)
        defer { reset(statement) }

        try bind(bindings, to: statement, sql: sql)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw PicknickError.storeFailure(operation: sql, message: lastErrorMessage)
        }
    }

    func query<T>(
        _ sql: String,
        _ bindings: [SQLiteValue] = [],
        decode: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let statement = try prepared(sql)
        defer { reset(statement) }

        try bind(bindings, to: statement, sql: sql)

        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            switch status {
            case SQLITE_ROW:
                results.append(try decode(SQLiteRow(statement: statement)))
            case SQLITE_DONE:
                return results
            default:
                throw PicknickError.storeFailure(operation: sql, message: lastErrorMessage)
            }
        }
    }

    /// Wraps `body` in a transaction, rolling back on any thrown error.
    ///
    /// Nesting is not supported and not needed: the store exposes exactly one
    /// transactional entry point.
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

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] { return cached }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw PicknickError.storeFailure(operation: "prepare", message: lastErrorMessage)
        }

        statementCache[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard values.count == expected else {
            throw PicknickError.storeFailure(
                operation: sql,
                message: "expected \(expected) bindings, received \(values.count)"
            )
        }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case let .integer(number):
                sqlite3_bind_int64(statement, index, number)
            case let .real(number):
                sqlite3_bind_double(statement, index, number)
            case let .text(string):
                sqlite3_bind_text(statement, index, string, -1, transientDestructor)
            case let .blob(data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
                }
            }

            guard status == SQLITE_OK else {
                throw PicknickError.storeFailure(operation: sql, message: lastErrorMessage)
            }
        }
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}
