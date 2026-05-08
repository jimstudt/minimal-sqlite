//
//  Statement.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//

import Foundation
import SQLite3

extension MinimalSQLite.SQLDatabase {
    /// A prepared SQLite statement owned by a database connection.
    ///
    /// `Statement` is an internal helper used by the public execute and query
    /// APIs. It prepares SQL, binds values, steps through result rows, and
    /// finalizes the underlying SQLite statement when the operation finishes.
    struct Statement {
        let db: OpaquePointer
        let stmt: OpaquePointer
        
        /// Prepares SQL text for execution on the given SQLite connection.
        init(db: OpaquePointer, sql: String) throws {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &s, nil) != SQLITE_OK {
                throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            self.db = db
            self.stmt = s!
        }
        
        /// Releases the prepared statement.
        func finalize() { sqlite3_finalize(stmt) }
        
        /// Resets the statement so it can be stepped again with fresh bindings.
        mutating func reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        
        /// Binds a variadic list of Swift values to the statement's placeholders.
        mutating func bind<each A: Value>(_ args: repeat each A) throws {
            // SQLite bind indices start at 1.
            var i: Int32 = 1
            for a in repeat each args {
                try a.bind(to: stmt, index: i)
                i += 1
            }
        }
        
        /// Advances the statement to the next row or completion state.
        mutating func step() throws -> Int32 {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW || rc == SQLITE_DONE { return rc }
            throw Error.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
    
    /// Executes SQL that does not need bound parameters or returned rows.
    ///
    /// Use this method for schema changes, pragmas, and simple SQL statements
    /// that can be passed directly to SQLite. For SQL that includes user data,
    /// prefer one of the parameterized `execute` overloads so values are bound
    /// safely instead of interpolated into the SQL string.
    ///
    /// ```swift
    /// try await database.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
    /// ```
    ///
    /// - Parameter sql: The SQL string to execute.
    /// - Throws: `SQLDatabase.Error.sqlite3Error` if the database is closed or
    ///   SQLite fails to execute the statement.
    public func execute(_ sql: String) async throws {
        try await sqlTask {
            guard let db = self.db else {
                throw Error.sqlite3Error(SQLITE_MISUSE, "database is not open")
            }
            var cErrMsg: UnsafeMutablePointer<CChar>? = nil
            let rc = sqlite3_exec(db, sql, nil, nil, &cErrMsg)
            if rc != SQLITE_OK {
                let message: String
                if let cErrMsg {
                    message = String(cString: cErrMsg)
                    sqlite3_free(cErrMsg)
                } else {
                    message = String(cString: sqlite3_errmsg(db))
                }
                throw Error.sqlite3Error(rc, message)
            }
        }
    }

    /// Executes parameterized SQL that does not need returned rows.
    ///
    /// Use `?` placeholders in the SQL string, then pass the Swift values to
    /// bind to those placeholders in the same order. The number of values must
    /// match the number of placeholders in the prepared statement.
    ///
    /// ```swift
    /// try await database.execute(
    ///     "INSERT INTO users (name, age) VALUES (?, ?)",
    ///     parameters: ["Ana", 42]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL text with `?` placeholders.
    ///   - parameters: The values to bind to placeholders in order.
    /// - Throws: `SQLDatabase.Error.parameterCountMismatch` if the number of
    ///   values does not match the number of placeholders, or another
    ///   `SQLDatabase.Error` if preparing, binding, or stepping fails.
    public func execute(_ sql: String, parameters: [any Value]) async throws {
        try await sqlTask {
            guard let db = self.db else {
                throw Error.sqlite3Error(SQLITE_MISUSE, "database is not open")
            }
            var stmt: OpaquePointer?
            let rcPrep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rcPrep == SQLITE_OK, let stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw Error.sqlite3Error(rcPrep, msg)
            }
            defer { sqlite3_finalize(stmt) }

            let expected = sqlite3_bind_parameter_count(stmt)
            if expected != Int32(parameters.count) {
                throw Error.parameterCountMismatch(expected: expected, got: parameters.count)
            }
            // Bind parameters (1-based indices)
            for (i, value) in parameters.enumerated() {
                let idx = Int32(i + 1)
                try value.bind(to: stmt, index: idx)
            }

            let rcStep = sqlite3_step(stmt)
            if rcStep != SQLITE_DONE && rcStep != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw Error.sqlite3Error(rcStep, msg)
            }
        }
    }

    /// Executes parameterized SQL using a variadic list of bound values.
    ///
    /// This is a convenience overload for callers who prefer passing bound
    /// values inline instead of building an array.
    ///
    /// ```swift
    /// try await database.execute(
    ///     "INSERT INTO users (name, age) VALUES (?, ?)",
    ///     "Ana",
    ///     42
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL text with `?` placeholders.
    ///   - parameters: The values to bind to placeholders in order.
    public func execute(_ sql: String, _ parameters: any Value...) async throws {
        try await execute(sql, parameters: parameters)
    }
    
    /// Reads at most one typed row from a parameterized query.
    ///
    /// `lookup` is useful for queries that should return zero or one row, such
    /// as lookups by primary key. The result type is a tuple whose element types
    /// must match the selected SQLite columns in order.
    ///
    /// ```swift
    /// let user: (Int, String)? = try await database.lookup(
    ///     "SELECT id, name FROM users WHERE id = ?",
    ///     parameters: [userID]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL query to run.
    ///   - parameters: The values to bind to `?` placeholders in order.
    /// - Returns: The single row returned by the query, or `nil` if the query
    ///   returns no rows.
    /// - Throws: `SQLDatabase.Error.rowNotUnique` if the query returns more than
    ///   one row, or another `SQLDatabase.Error` if preparing, binding,
    ///   stepping, or reading values fails.
    public func lookup<each T: Value>( _ sql: String, parameters: [any Value]) async throws -> (repeat each T)? {
        let rows : [(repeat each T)] = try await self.query(sql, parameters: parameters)
        
        if rows.count > 1 {
            throw SQLDatabase.Error.rowNotUnique
        }

        guard let result = rows.first else {
            return nil
        }
        if rows.count == 0 {
            return nil
        }
        return result
    }
    
    /// Runs a parameterized query and reads each row as a typed tuple.
    ///
    /// The tuple element types determine how columns are decoded. Select the
    /// same number of columns as the tuple contains, in the same order, and use
    /// types that conform to `SQLDatabase.Value`.
    ///
    /// ```swift
    /// let users: [(Int, String)] = try await database.query(
    ///     "SELECT id, name FROM users WHERE age >= ? ORDER BY name",
    ///     parameters: [18]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL query to run.
    ///   - parameters: The values to bind to `?` placeholders in order.
    /// - Returns: An array containing one typed tuple for each row returned by
    ///   SQLite.
    /// - Throws: A `SQLDatabase.Error` if the database is closed or if preparing,
    ///   binding, stepping, or reading values fails.
    public func query<each T: Value>(
      _ sql: String,
      parameters: [any Value]
    ) async throws -> [(repeat each T)] {
        return try await sqlTask {
            guard let db = self.db else {
                throw Error.sqlite3Error(SQLITE_MISUSE, "database is not open")
            }

            var st = try Statement(db: db, sql: sql)
            defer { st.finalize() }

            // Bind parameters from array (1-based)
            for (i, value) in parameters.enumerated() {
                try value.bind(to: st.stmt, index: Int32(i + 1))
            }

            var out: [(repeat each T)] = []
            while true {
                let rc = try st.step()
                if rc == SQLITE_DONE { break }
                out.append(try decodeTupleRow(stmt: st.stmt, as: (repeat each T).self))
            }
            return out
        }

        @Sendable @inline(__always)
        func decodeTupleRow<each X: Value>(
            stmt: OpaquePointer,
            as _: (repeat each X).Type
        ) throws -> (repeat each X) {
            var col: Int32 = 0
            func readOne<U: Value>(_ _: U.Type) throws -> U {
                defer { col += 1 }
                return try U.read(from: stmt, col: col)
            }
            return (repeat try readOne((each X).self))
        }
    }

    /// Runs a parameterized query with variadic bound values.
    ///
    /// This is a convenience overload for `query(_:parameters:)` that lets you
    /// pass placeholder values inline. The result type still comes from the
    /// expected return type at the call site.
    ///
    /// ```swift
    /// let users: [(Int, String)] = try await database.query(
    ///     "SELECT id, name FROM users WHERE age >= ? ORDER BY name",
    ///     bind: 18
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL query to run.
    ///   - args: The values to bind to `?` placeholders in order.
    /// - Returns: An array containing one typed tuple for each row returned by
    ///   SQLite.
    public func query<each T: Value, each A: Value>(
      _ sql: String,
      bind args: repeat each A
    ) async throws -> [(repeat each T)] {
        var params: [any Value] = []
        for a in repeat each args { params.append(a) }
        return try await query(sql, parameters: params)
    }
    

    /// Runs a query and returns each row as a dictionary keyed by column name.
    ///
    /// Use `queryDict` when the set of selected columns is dynamic or when a
    /// dictionary is more convenient than a typed tuple. SQLite `INTEGER`,
    /// `FLOAT`, `TEXT`, and `BLOB` values are returned as `Int`, `Double`,
    /// `String`, and `Data`. `NULL` columns are omitted from the row dictionary.
    ///
    /// ```swift
    /// let rows = try await database.queryDict(
    ///     "SELECT id, name, avatar FROM users WHERE age >= ?",
    ///     bind: [18]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL query to run.
    ///   - bind: The values to bind to `?` placeholders in order.
    /// - Returns: An array of dictionaries, one dictionary per row.
    /// - Throws: A `SQLDatabase.Error` if the database is closed or if preparing,
    ///   binding, or stepping fails.
    public func queryDict(
        _ sql: String,
        bind: [any Value]
    ) async throws -> [[String: any Value]] {
        return try await sqlTask {
            guard let db = self.db else {
                throw Error.sqlite3Error(SQLITE_MISUSE, "database is not open")
            }

            var st = try Statement(db: db, sql: sql)
            defer { st.finalize() }

            // Bind parameters from array (1-based)
            for (i, value) in bind.enumerated() {
                try value.bind(to: st.stmt, index: Int32(i + 1))
            }

            var out: [[String: any Value]] = []
            let columnCount = sqlite3_column_count(st.stmt)

            while true {
                let rc = try st.step()
                if rc == SQLITE_DONE { break }

                var row: [String: any Value] = [:]
                for i in 0..<columnCount {
                    let idx = Int32(i)
                    let name = String(cString: sqlite3_column_name(st.stmt, idx))
                    switch sqlite3_column_type(st.stmt, idx) {
                    case SQLITE_INTEGER:
                        let v = Int(sqlite3_column_int64(st.stmt, idx))
                        row[name] = v
                    case SQLITE_FLOAT:
                        let v = Double(sqlite3_column_double(st.stmt, idx))
                        row[name] = v
                    case SQLITE_TEXT:
                        if let cstr = sqlite3_column_text(st.stmt, idx) {
                            row[name] = String(cString: cstr)
                        } else {
                            row[name] = ""
                        }
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(st.stmt, idx))
                        if count > 0, let bytes = sqlite3_column_blob(st.stmt, idx) {
                            row[name] = Data(bytes: bytes, count: count)
                        } else {
                            row[name] = Data()
                        }
                    case SQLITE_NULL:
                        // Skip NULL so they just aren't in the dictionary
                        break
                    default:
                        // Skip if an unknown type is encountered
                        break
                    }
                }
                out.append(row)
            }
            return out
        }
    }

    /// Runs a dictionary query with variadic bound values.
    ///
    /// This convenience overload behaves like `queryDict(_:bind:)`, but accepts
    /// placeholder values inline instead of as an array.
    ///
    /// ```swift
    /// let rows = try await database.queryDict(
    ///     "SELECT id, name FROM users WHERE age >= ?",
    ///     bind: 18
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - sql: The SQL query to run.
    ///   - args: The values to bind to `?` placeholders in order.
    /// - Returns: An array of dictionaries, one dictionary per row.
    public func queryDict<each A: Value>(
        _ sql: String,
        bind args: repeat each A
    ) async throws -> [[String: any Value]] {
        var params: [any Value] = []
        for a in repeat each args { params.append(a) }
        return try await queryDict(sql, bind: params)
    }
    
    
}
