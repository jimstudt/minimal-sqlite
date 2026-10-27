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

private func textPragma(_ handle: OpaquePointer, _ statement: String) throws -> String {
    var sqliteStatement: OpaquePointer?
    let prepareRC = sqlite3_prepare_v2(handle, statement, -1, &sqliteStatement, nil)
    guard prepareRC == SQLITE_OK, let sqliteStatement else {
        try throwSQLiteError(code: prepareRC, handle: handle)
    }
    defer { sqlite3_finalize(sqliteStatement) }

    let stepRC = sqlite3_step(sqliteStatement)
    guard stepRC == SQLITE_ROW else {
        if stepRC == SQLITE_DONE {
            throw MinimalSQLite.SQLDatabase.Error.readFailed("pragma returned no value: \(statement)")
        }
        try throwSQLiteError(code: stepRC, handle: handle)
    }
    guard let text = sqlite3_column_text(sqliteStatement, 0) else {
        throw MinimalSQLite.SQLDatabase.Error.readFailed("pragma returned NULL: \(statement)")
    }
    return String(cString: text)
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
    /// SQLite's persistent and per-connection rollback-journal modes.
    public enum JournalMode: String, Sendable {
        /// Uses SQLite's default rollback journal and deletes it after a transaction.
        case delete = "DELETE"
        /// Truncates the rollback journal to zero bytes after a transaction.
        case truncate = "TRUNCATE"
        /// Reuses the rollback journal after marking it inactive.
        case persist = "PERSIST"
        /// Stores the rollback journal in memory.
        case memory = "MEMORY"
        /// Uses SQLite's write-ahead log.
        case wal = "WAL"
        /// Disables the rollback journal.
        ///
        /// This mode removes SQLite's rollback protection and is rarely
        /// appropriate for application databases.
        case off = "OFF"
    }

    /// An opaque identity for a SQLite connection owned by the database.
    ///
    /// Transaction actors expose their connection to satisfy ``Transaction``.
    /// Applications normally use the transaction's statement methods instead
    /// of interacting with a connection directly.
    public struct Connection: Hashable, @unchecked Sendable {
        let handle: OpaquePointer

        /// Returns whether two values refer to the same SQLite connection.
        public static func == (lhs: Connection, rhs: Connection) -> Bool {
            lhs.handle == rhs.handle
        }

        /// Hashes the identity of the underlying SQLite connection.
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
        /// SQLite could not activate the requested journal mode for this database.
        case journalModeUnavailable(database: String, requested: String, actual: String)
        /// A query expected exactly one row but returned a different number of rows.
        case rowNotUnique
        /// A database operation was attempted after its connections were closed.
        case databaseClosed
        /// A backup destination was invalid, already existed, or referred to the source database.
        case invalidBackupDestination(String)
    }

    private let databaseURL: URL?
    

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
    ///   - journalMode: A journal mode to apply on the writer before any reader
    ///     handles are opened. Use this instead of changing `journal_mode`
    ///     inside a transaction.
    /// - Throws: `SQLDatabase.Error.sqlite3Error` if SQLite cannot open the
    ///   database, configure its pragmas, or open one of its readonly reader
    ///   handles.
    public init(
        at url: URL?,
        canCreate: Bool = true,
        readOnly: Bool = false,
        readers: Int = 4,
        foreignKeys: Bool = true,
        journalMode: JournalMode? = nil
    ) throws {
        self.databaseURL = url?.standardizedFileURL
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
            if let journalMode {
                let actualMode = try textPragma(writerHandle, "PRAGMA journal_mode = \(journalMode.rawValue);")
                guard actualMode.caseInsensitiveCompare(journalMode.rawValue) == .orderedSame else {
                    throw Error.journalModeUnavailable(
                        database: databaseName,
                        requested: journalMode.rawValue,
                        actual: actualMode
                    )
                }
            }
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
        } catch let Error.sqlite3Error(code, message) {
            sqlite3_close(writerHandle)
            for readerHandle in readerHandles {
                sqlite3_close(readerHandle)
            }
            throw Error.sqlite3Error(code, "\(databaseName): \(message)")
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

    /// Creates a consistent, standalone copy of an open database.
    ///
    /// The backup includes committed changes that are still present only in a
    /// write-ahead log. MinimalSQLite reserves the writer connection for the
    /// duration of the copy, so application writes wait while existing readers
    /// may continue. The destination must not already exist and must not refer
    /// to the source database.
    ///
    /// The copy is performed in bounded batches. SQLite lock contention is
    /// retried asynchronously, and task cancellation stops the backup. Callers
    /// that need atomic replacement should back up to a temporary URL and move
    /// the completed file into place themselves.
    public func backup(to destinationURL: URL) async throws {
        try await backup(to: destinationURL, pagesPerStep: 256) {}
    }

    /// Internal controls keep the public API small while allowing deterministic
    /// tests of suspension, cancellation, and writer serialization.
    func backup(
        to destinationURL: URL,
        pagesPerStep: Int32,
        afterOpen: @escaping @Sendable () async throws -> Void = {},
        afterStep: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard pagesPerStep > 0 else {
            throw Error.invalidBackupDestination("pages per step must be positive")
        }
        let destinationURL = destinationURL.standardizedFileURL
        if databaseURL == destinationURL {
            throw Error.invalidBackupDestination("the destination is the source database")
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw Error.invalidBackupDestination("the destination already exists")
        }

        try await writerPool.with { source in
            try Task.checkCancellation()

            var destination: OpaquePointer?
            let openRC = destinationURL.path.withCString { path in
                sqlite3_open_v2(
                    path,
                    &destination,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE,
                    nil
                )
            }
            guard openRC == SQLITE_OK, let destination else {
                if let destination { sqlite3_close(destination) }
                try throwSQLiteError(code: openRC, message: "unable to create backup destination")
            }
            var completed = false
            defer {
                sqlite3_close(destination)
                if !completed { try? FileManager.default.removeItem(at: destinationURL) }
            }

            try await afterOpen()

            guard let backup = sqlite3_backup_init(destination, "main", source.handle, "main") else {
                try throwSQLiteError(code: sqlite3_errcode(destination), handle: destination)
            }
            var finished = false
            defer {
                if !finished { sqlite3_backup_finish(backup) }
            }

            while true {
                try Task.checkCancellation()
                switch sqlite3_backup_step(backup, pagesPerStep) {
                case SQLITE_DONE:
                    let finishRC = sqlite3_backup_finish(backup)
                    finished = true
                    guard finishRC == SQLITE_OK else {
                        try throwSQLiteError(code: finishRC, handle: destination)
                    }
                    completed = true
                    return
                case SQLITE_OK:
                    try await afterStep()
                    await Task.yield()
                case SQLITE_BUSY, SQLITE_LOCKED:
                    try await Task.sleep(for: .milliseconds(10))
                case let code:
                    try throwSQLiteError(code: code, handle: destination)
                }
            }
        }
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
