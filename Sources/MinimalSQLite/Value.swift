//
//  Value.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//
import Foundation
import SQLite3

extension MinimalSQLite.SQLDatabase {
    /// A Swift type that can be bound to SQLite statements and read from SQLite rows.
    ///
    /// `Value` is the conversion layer used by `SQLDatabase` statement APIs.
    /// When you pass parameters to `execute`, `query`, `lookup`, or `queryDict`,
    /// each parameter must conform to `Value` so it can bind itself to a SQLite
    /// statement placeholder. When you read typed query results, the tuple's
    /// element types must conform to `Value` so each selected SQLite column can
    /// be decoded into the requested Swift type.
    ///
    /// The package provides conformances for these types:
    /// `Int64`, `Int`, `String`, `Bool`, `Double`, `Date`, `Data`, `Null`, and
    /// `Optional<Wrapped>` when `Wrapped` also conforms to `Value`.
    ///
    /// Implement this protocol for your own types when you want them to be used
    /// directly as statement parameters or typed result columns. `bind(to:index:)`
    /// writes the value into a prepared statement's 1-based placeholder index,
    /// and `read(from:col:)` reads from a result row's 0-based column index.
    public protocol Value : Sendable {
        /// Reads this Swift value from a SQLite result column.
        static func read(from stmt: OpaquePointer, col: Int32) throws -> Self
        /// Binds this Swift value to a SQLite statement placeholder.
        func bind(to stmt: OpaquePointer, index: Int32) throws
    }
}

/// SQLite integer storage for `Int64` values.
extension Int64: MinimalSQLite.SQLDatabase.Value {
    /// Reads an integer column with SQLite's 64-bit integer API.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> Int64 {
        // If you want strictness, check sqlite3_column_type here.
        sqlite3_column_int64(stmt, col)
    }
    /// Binds the value with SQLite's 64-bit integer API.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        if sqlite3_bind_int64(stmt, index, self) != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}

/// SQLite integer storage for `Int` values.
extension Int: MinimalSQLite.SQLDatabase.Value {
    /// Reads an integer column and converts it to `Int`.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> Int {
        // If you want strictness, check sqlite3_column_type here.
        Int( sqlite3_column_int64(stmt, col))
    }
    /// Binds the value with SQLite's 64-bit integer API.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        if sqlite3_bind_int64(stmt, index, sqlite3_int64(self)) != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}

/// SQLite text storage for `String` values.
extension String: MinimalSQLite.SQLDatabase.Value {
    /// Reads a text column as a Swift string.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" } // or throw on NULL
        return String(cString: c)
    }
    /// Binds the string as SQLite text.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        // SQLITE_TRANSIENT so SQLite copies the bytes.
        let rc = sqlite3_bind_text(stmt, index, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if rc != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}

/// SQLite integer storage for `Bool` values.
extension Bool: MinimalSQLite.SQLDatabase.Value {
    /// Reads a nonzero SQLite integer as `true` and zero as `false`.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> Bool {
        sqlite3_column_int64(stmt, col) != 0
    }
    /// Binds `true` as `1` and `false` as `0`.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        let v: Int32 = self ? 1 : 0
        if sqlite3_bind_int(stmt, index, v) != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}

/// SQLite floating-point storage for `Double` values.
extension Double: MinimalSQLite.SQLDatabase.Value {
    /// Reads a floating-point column as a Swift double.
    public static func read(from stmt: OpaquePointer, col: Int32) throws -> Double {
        sqlite3_column_double(stmt, col)
    }
    /// Binds the value with SQLite's double API.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        if sqlite3_bind_double(stmt, index, self) != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}

/// SQLite integer or text storage for `Date` values.
extension Date: MinimalSQLite.SQLDatabase.Value {
    /// Reads a date from an integer epoch value or ISO 8601 text.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> Date {
        let colType = sqlite3_column_type(stmt, col)
        switch colType {
        case SQLITE_INTEGER:
            let epoch = Int64( sqlite3_column_int64(stmt, col))
            return Date(timeIntervalSince1970: TimeInterval(integerLiteral: epoch))
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, col) else {
                throw MinimalSQLite.SQLDatabase.Error.readFailed("Unable to read Date from column")
            }
            
            let s = String(cString: c)

            // An integer gets us epoch style
            if let epoch = Int64(s) {
                return Date(timeIntervalSince1970: TimeInterval(integerLiteral: epoch))
            }

            // Otherwise try ISO8601
            let formatter = ISO8601DateFormatter()
            guard let d = formatter.date(from: s) else {
                throw MinimalSQLite.SQLDatabase.Error.readFailed("Unable to decode Date from \(s)")
            }
            return d
        default:
            let namePtr = sqlite3_column_name(stmt, col)
            let colName = namePtr != nil ? String(cString: namePtr!) : "<unknown>"
            throw MinimalSQLite.SQLDatabase.Error.readFailed("Unsupported SQLite column (\(colName)) type (\(colType)) for reading Date")
        }
    }
    /// Binds the date as an integer Unix epoch timestamp.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        let epoch : Int = self.timeIntervalSince1970.isNaN ? 0 : Int(self.timeIntervalSince1970)
        if sqlite3_bind_int64(stmt, index, sqlite3_int64(epoch)) != SQLITE_OK {
            throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }
}


/// SQLite `NULL` support for optional values.
extension Optional: MinimalSQLite.SQLDatabase.Value where Wrapped: MinimalSQLite.SQLDatabase.Value {
    /// Reads `NULL` as `nil`, otherwise reads the wrapped value.
    static public func read(from stmt: OpaquePointer, col: Int32) throws -> Optional<Wrapped> {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return try Wrapped.read(from: stmt, col: col)
    }
    /// Binds `nil` as `NULL`, otherwise binds the wrapped value.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        switch self {
        case .none:
            if sqlite3_bind_null(stmt, index) != SQLITE_OK {
                throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
            }
        case .some(let w):
            try w.bind(to: stmt, index: index)
        }
    }
}

/// Represents an explicit SQLite `NULL` value.
///
/// Use `Null` when you need a concrete value that binds as SQLite `NULL` rather
/// than an optional value.
public struct Null: MinimalSQLite.SQLDatabase.Value {
    public init() {}
    /// Binds the value as SQLite `NULL`.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        sqlite3_bind_null(stmt, index)
    }
    /// Reads a `NULL` column as `Null`.
    public static func read(from stmt: OpaquePointer, col: Int32) throws -> Null {
        return Null()
    }
}

/// SQLite blob storage for `Data` values.
extension Data: MinimalSQLite.SQLDatabase.Value {
    /// Reads a blob column as Swift data.
    public static func read(from stmt: OpaquePointer, col: Int32) throws -> Data {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, col))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    /// Binds the data as a SQLite blob.
    public func bind(to stmt: OpaquePointer, index: Int32) throws {
        try self.withUnsafeBytes { rawBuf in
            let rc = sqlite3_bind_blob(stmt, index, rawBuf.baseAddress, Int32(self.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if rc != SQLITE_OK {
                throw MinimalSQLite.SQLDatabase.Error.bindFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
            }
        }
    }
}

