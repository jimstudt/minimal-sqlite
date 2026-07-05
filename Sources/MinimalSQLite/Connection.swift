//
//  Connection.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func throwSQLiteError(code: Int32, message: String) throws -> Never {
    let primary = code & 0xFF
    if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
        throw MinimalSQLite.SQLDatabase.Error.transactionLocked(message)
    }
    throw MinimalSQLite.SQLDatabase.Error.sqlite3Error(code, message)
}

func throwSQLiteError(code: Int32, handle: OpaquePointer) throws -> Never {
    try throwSQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
}

private func pragma(_ handle: OpaquePointer, _ statement: String) throws {
    let rc = sqlite3_exec(handle, statement, nil, nil, nil)
    guard rc == SQLITE_OK else {
        try throwSQLiteError(code: rc, handle: handle)
    }
}

/// An actor that owns SQLite database handles.
///
/// `SQLDatabase` keeps a writer handle and optional readonly reader handles.
/// Create one database actor for each SQLite database you want to work with,
/// then call the package's async APIs on that actor to create tables, run
/// statements, and read rows.
///
/// Pass a file URL to open an on-disk database, or pass `nil` to create a
/// temporary shared-cache in-memory database that exists only while its handles
/// remain open.
public actor SQLDatabase {
    public struct Connection: Hashable, @unchecked Sendable {
        let handle: OpaquePointer

        public static func == (lhs: Connection, rhs: Connection) -> Bool {
            lhs.handle == rhs.handle
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(UInt(bitPattern: handle))
        }
    }

    let writerPool: AsyncTokenPool<Connection>
    let readerPool: AsyncTokenPool<Connection>
    
    /// Errors thrown by SQLite connection, statement, and row-reading operations.
    public enum Error : Swift.Error {
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
        /// SQLite could not advance a statement because the transaction was locked.
        case transactionLocked(String)
        /// SQLite failed while advancing or executing a statement.
        case stepFailed(String)
        /// A query expected exactly one row but returned a different number of rows.
        case rowNotUnique
        case databaseClosed
    }
    

    /// Opens a SQLite database connection.
    ///
    /// Use this initializer to create either a file-backed database or an
    /// in-memory database. File-backed databases are opened with their file
    /// path. In-memory databases are opened with a generated SQLite URI so the
    /// writer and reader handles can share the same temporary database.
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
    ///   - readers: The number of readonly reader handles to open.
    ///   - foreignKeys: Pass `true` to enable SQLite foreign-key enforcement on
    ///     every writer and reader connection.
    /// - Throws: `SQLDatabase.Error.sqlite3Error` if SQLite cannot open the
    ///   database, configure its pragmas, or open one of its readonly reader
    ///   handles.
    public init(at url: URL?, canCreate: Bool = true, readOnly: Bool = false, readers: Int = 4, foreignKeys: Bool = true) throws {
        let databaseName: String
        let writerFlags: Int32
        let readerFlags: Int32
        if let url {
            databaseName = url.path
            if readOnly {
                writerFlags = SQLITE_OPEN_READONLY
            } else {
                writerFlags = SQLITE_OPEN_READWRITE | (canCreate ? SQLITE_OPEN_CREATE : 0)
            }
            readerFlags = SQLITE_OPEN_READONLY
        } else {
            databaseName = "file:minimal-sqlite-\(UUID().uuidString)?mode=memory&cache=shared"
            writerFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
            readerFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        }

        var writerHandle: OpaquePointer?
        let writerRC = databaseName.withCString { cPath in
            sqlite3_open_v2(cPath, &writerHandle, writerFlags, nil)
        }

        guard writerRC == SQLITE_OK, let writerHandle else {
            let msg: String
            if let writerHandle {
                msg = String(cString: sqlite3_errmsg(writerHandle))
                sqlite3_close(writerHandle)
            } else {
                msg = "unable to open database"
            }
            try throwSQLiteError(code: writerRC, message: msg)
        }

        var readerHandles: [OpaquePointer] = []
        do {
            if foreignKeys { try pragma(writerHandle, "PRAGMA foreign_keys = ON;") }
            try pragma(writerHandle, "PRAGMA synchronous = NORMAL")

            for _ in 0..<max(0, readers) {
                var readerHandle: OpaquePointer?
                let readerRC = databaseName.withCString { cPath in
                    sqlite3_open_v2(cPath, &readerHandle, readerFlags, nil)
                }

                guard readerRC == SQLITE_OK, let readerHandle else {
                    let msg: String
                    if let readerHandle {
                        msg = String(cString: sqlite3_errmsg(readerHandle))
                        sqlite3_close(readerHandle)
                    } else {
                        msg = "unable to open readonly database handle"
                    }
                    try throwSQLiteError(code: readerRC, message: msg)
                }

                do {
                    if foreignKeys { try pragma(readerHandle, "PRAGMA foreign_keys = ON;") }
                    try pragma(readerHandle, "PRAGMA query_only = ON;")
                } catch {
                    sqlite3_close(readerHandle)
                    throw error
                }

                readerHandles.append(readerHandle)
            }
        } catch {
            sqlite3_close(writerHandle)
            for readerHandle in readerHandles {
                sqlite3_close(readerHandle)
            }
            throw error
        }

        self.writerPool = AsyncTokenPool([Connection(handle: writerHandle)])
        self.readerPool = AsyncTokenPool(Set(readerHandles.map { Connection(handle: $0) }))
    }

    deinit {
        // This is kind of an emergency bandaid, you really should have closed it first.
        Task { [writerPool, readerPool] in
            for t in await writerPool.removeAllTokens() {
                sqlite3_close(t.handle)
            }
            for t in await readerPool.removeAllTokens() {
                sqlite3_close(t.handle)
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
        for t in await writerPool.removeAllTokens() {
            sqlite3_close(t.handle)
        }
        for t in await readerPool.removeAllTokens() {
            sqlite3_close(t.handle)
        }
    }

    
    /// Runs write-capable database work inside an immediate SQLite transaction.
    ///
    /// The transaction begins before `block` runs. If the block completes
    /// successfully, the transaction is committed and the block's return value
    /// is returned. If the block throws, the transaction is rolled back and the
    /// error is rethrown.
    ///
    /// SQLite `BUSY` and `LOCKED` errors are treated as retryable. When one of
    /// those errors is thrown as `SQLDatabase.Error.sqlite3Error`, the current
    /// transaction is rolled back and the entire transaction block is run again.
    /// For that reason, the block should be safe to retry. Keep side effects
    /// that are outside SQLite, such as network requests or file writes, out of
    /// the block or make them idempotent.
    ///
    /// ```swift
    /// let status = try await database.readwrite { transaction in
    ///     try await transaction.execute(
    ///         "INSERT INTO users (name) VALUES (?)",
    ///         "Blob"
    ///     )
    ///     return "inserted"
    /// }
    /// ```
    ///
    /// - Parameter block: The async work to run while the transaction is active.
    /// - Returns: The value returned by `block` after a successful commit.
    /// - Throws: The error thrown by `block`, or an error thrown while beginning,
    ///   committing, rolling back, or retrying the transaction.
    public func readwrite<T: Sendable>(_ block: @Sendable ( WriteTransaction) async throws -> T) async throws -> T {
        try await writerPool.with { connection in
            let tx = WriteTransaction(connection: connection)
            
            while true {
                try await tx.begin(mode: .immediate)
                do {
                    let result = try await block(tx)
                    try await tx.commit()
                    return result
                } catch Error.transactionLocked(_) {
                    try? await tx.rollback()
                    continue
                } catch let Error.sqlite3Error(code, message) {
                    // Always attempt rollback on error
                    try? await tx.rollback()
                    // Check primary result code for retryable lock conditions
                    let primary = code & 0xFF
                    if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
                        // Retry the transaction
                        continue
                    } else {
                        // Non-retryable SQLite error
                        throw Error.sqlite3Error(code, message)
                    }
                } catch {
                    // Non-SQLite error: rollback and rethrow
                    try? await tx.rollback()
                    throw error
                }
            }
        }
    }
    
    /// Runs read-only database work inside a deferred SQLite transaction.
    ///
    /// The block receives a `ReadTransaction`, which exposes query APIs but not
    /// write APIs. SQLite `BUSY` and `LOCKED` errors are treated as retryable in
    /// the same way as `readwrite(_:)`.
    ///
    /// ```swift
    /// let users: [(Int, String)] = try await database.readonly { transaction in
    ///     try await transaction.query(
    ///         "SELECT id, name FROM users ORDER BY name"
    ///     )
    /// }
    /// ```
    ///
    /// - Parameter block: The async work to run while the transaction is active.
    /// - Returns: The value returned by `block` after a successful commit.
    /// - Throws: The error thrown by `block`, or an error thrown while beginning,
    ///   committing, rolling back, or retrying the transaction.
    public func readonly<T: Sendable>(_ block: @Sendable ( ReadTransaction) async throws -> T) async throws -> T {
        try await readerPool.with { connection in
            let tx = ReadTransaction(connection: connection)
            while true {
                try await tx.begin(mode: .deferred)
                do {
                    let result = try await block(tx)
                    try await tx.commit()
                    return result
                } catch Error.transactionLocked(_) {
                    try? await tx.rollback()
                    continue
                } catch let Error.sqlite3Error(code, message) {
                    // Always attempt rollback on error
                    try? await tx.rollback()
                    // Check primary result code for retryable lock conditions
                    let primary = code & 0xFF
                    if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
                        // Retry the transaction
                        continue
                    } else {
                        // Non-retryable SQLite error
                        throw Error.sqlite3Error(code, message)
                    }
                } catch {
                    // Non-SQLite error: rollback and rethrow
                    try? await tx.rollback()
                    throw error
                }
            }
        }
    }

}
