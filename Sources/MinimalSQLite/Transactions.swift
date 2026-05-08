//
//  Transactions.swift
//  Mailecule
//
//  Created by Jim Studt on 2/19/26.
//

import Foundation
import SQLite3


extension MinimalSQLite.SQLDatabase {
    /// The kind of SQLite transaction to begin.
    ///
    /// SQLite transaction modes control when the database acquires read and
    /// write locks. Most callers should use `.deferred`, which is SQLite's
    /// default behavior. Use `.immediate` or `.exclusive` when you need lock
    /// acquisition to happen at the start of the transaction instead of later
    /// when a write statement is executed.
    public enum TransactionMode {
        /// Begins a deferred transaction.
        ///
        /// A deferred transaction does not acquire a write lock until one is
        /// needed. This is the usual choice for transactions that may only read
        /// or that should avoid taking a write lock until the first write.
        case deferred
        /// Begins an immediate transaction.
        ///
        /// An immediate transaction attempts to acquire a write lock at the
        /// start. Use this when the block is expected to write and you want lock
        /// contention to be detected before running the transaction body.
        case immediate
        /// Begins an exclusive transaction.
        ///
        /// An exclusive transaction acquires the strongest SQLite transaction
        /// lock. Without write-ahead logging, this can block other connections
        /// from reading while the transaction is active.
        case exclusive
        
        var sql: String {
            switch self {
            case .deferred:          return "DEFERRED"
            case .immediate:        return "IMMEDIATE"
            case .exclusive:       return "EXCLUSIVE"
            }
        }
    }
    
    /// Runs a group of database operations inside a SQLite transaction.
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
    /// let id = try await database.transaction(.immediate) {
    ///     try await database.execute(
    ///         "INSERT INTO users (name) VALUES (?)",
    ///         ["Blob"]
    ///     )
    ///     return try await database.lastInsertRowID()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - mode: The SQLite transaction mode to use. The default is
    ///     `.deferred`.
    ///   - block: The async work to run while the transaction is active.
    /// - Returns: The value returned by `block` after a successful commit.
    /// - Throws: The error thrown by `block`, or an error thrown while beginning,
    ///   committing, rolling back, or retrying the transaction.
    public func transaction<T>(_ mode: TransactionMode = .deferred, _ block: ()async throws->T) async throws -> T {
        while true {
            try await execute("BEGIN \(mode.sql) TRANSACTION")
            do {
                let result = try await block()
                try await execute("COMMIT TRANSACTION")
                return result
            } catch let Error.sqlite3Error(code, message) {
                // Always attempt rollback on error
                try? await execute("ROLLBACK TRANSACTION")
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
                try? await execute("ROLLBACK TRANSACTION")
                throw error
            }
        }
    }
}
