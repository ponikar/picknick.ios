import Foundation
import SQLite3

/// Typed access to the current row of a stepping statement.
///
/// Valid only for the duration of the enumeration callback that receives it;
/// the underlying statement is reset once the query returns.
public struct SQLiteRow {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    public func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func bool(_ index: Int32) -> Bool {
        sqlite3_column_int64(statement, index) != 0
    }

    public func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public func optionalDouble(_ index: Int32) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(statement, index)
    }

    public func date(_ index: Int32) -> Date? {
        guard !isNull(index) else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }

    public func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalString(_ index: Int32) -> String? {
        isNull(index) ? nil : string(index)
    }

    public func data(_ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }
}
