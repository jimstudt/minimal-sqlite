//
//  Connection.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An actor that owns a single SQLite database connection.
///
/// `SQLDatabase` serializes all SQLite work through an internal queue so the
/// underlying `sqlite3` handle is only used by one operation at a time. Create
/// one database actor for each SQLite database you want to work with, then call
/// the package's async APIs on that actor to create tables, run statements,
/// and read rows.
///
/// Pass a file URL to open an on-disk database, or pass `nil` to create a
/// temporary in-memory database that exists only for the lifetime of the
/// connection.
public actor SQLDatabase {
    private let sqlQueue: DispatchQueue
    nonisolated(unsafe) var db: OpaquePointer?

    /// Errors thrown by SQLite connection, statement, and row-reading operations.
    enum Error : Swift.Error {
        /// A database open operation was requested while a handle was already open.
        case databaseAlreadyOpen
        /// SQLite returned an error code and message.
        case sqlite3Error(Int32, String)
        /// The number of bound Swift values did not match the statement's placeholders.
        case parameterCountMismatch(expected: Int32, got: Int)
        /// A Swift value could not be bound to a SQLite statement parameter.
        case bindFailed(String)
        /// A SQLite column value could not be converted into the requested Swift type.
        case readFailed(String)
        /// SQLite could not compile the SQL string into a prepared statement.
        case prepareFailed(String, sql: String)
        /// SQLite failed while advancing or executing a statement.
        case stepFailed(String)
        /// A query expected exactly one row but returned a different number of rows.
        case rowNotUnique
    }
    

    /// Opens a SQLite database connection.
    ///
    /// Use this initializer to create either a file-backed database or an
    /// in-memory database. File-backed databases are opened with
    /// `sqlite3_open_v2`; in-memory databases are opened with SQLite's
    /// `:memory:` database name.
    ///
    /// ```swift
    /// let database = try SQLDatabase(at: databaseURL)
    /// let memoryDatabase = try SQLDatabase(at: nil)
    /// ```
    ///
    /// - Parameters:
    ///   - url: The file URL for the SQLite database, or `nil` to open an
    ///     in-memory database.
    ///   - canCreate: Pass `true` to create the database file when it does not
    ///     already exist. This option is ignored when `readOnly` is `true` or
    ///     when `url` is `nil`.
    ///   - readOnly: Pass `true` to open an existing file-backed database
    ///     without write permission.
    /// - Throws: `SQLDatabase.Error.sqlite3Error` if SQLite cannot open the
    ///   database.
    public init(at url: URL?, canCreate: Bool = true, readOnly: Bool = false) throws {
        self.sqlQueue = DispatchQueue(label: "com.lunarware.minimalsqlite.queue", qos: .default)

        var handle: OpaquePointer?
        let rc: Int32
        if let url {
            let flags: Int32
            if readOnly {
                flags = SQLITE_OPEN_READONLY
            } else {
                flags = SQLITE_OPEN_READWRITE | (canCreate ? SQLITE_OPEN_CREATE : 0)
            }
            rc = url.path.withCString { cPath in
                sqlite3_open_v2(cPath, &handle, flags, nil)
            }
        } else {
            // Open an in-memory database when URL is nil
            rc = sqlite3_open(":memory:", &handle)
        }

        guard rc == SQLITE_OK, let handle else {
            let msg: String
            if let handle {
                msg = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
            } else {
                msg = "unable to open database"
            }
            throw Error.sqlite3Error(rc, msg)
        }
        self.db = handle
    }

    deinit {
        // If our database is still open, then wait for the queue clear and do a close.
        if db != nil {
            _ = sqlQueue.sync {
                sqlite3_close(self.db)
            }
        }
    }
    
    /// Runs synchronous SQLite work on the connection's serial queue.
    ///
    /// SQLite's C API is blocking and uses the connection handle directly. This
    /// helper bridges that synchronous work into async package APIs while
    /// preserving one-at-a-time access to the handle.
    @discardableResult
    func sqlTask<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sqlQueue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Closes the SQLite database connection.
    ///
    /// Call `close()` when you want to release the SQLite handle before the
    /// database actor is deallocated. Calling `close()` on an already closed
    /// connection has no effect.
    ///
    /// After a connection is closed, create a new `SQLDatabase` instance before
    /// running more SQL.
    public func close() async throws {
        if db == nil { return }
        
        try await sqlTask {
            sqlite3_close(self.db)
        }
        self.db = nil
    }

    
    
}

