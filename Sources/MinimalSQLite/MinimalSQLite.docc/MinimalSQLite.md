# MinimalSQLite

Use SQLite from Swift with a small async API for connections, statements, values, and transactions.

## Overview

MinimalSQLite is a lightweight wrapper around SQLite's C API. It keeps the SQLite handle in a ``SQLDatabase`` actor, then exposes async methods for running SQL, binding Swift values, decoding rows, and grouping work in transactions.

The package is intentionally close to SQLite. You still write SQL directly, choose your schema, and decide which queries to run. MinimalSQLite handles the repetitive glue: opening and closing the database, preparing statements, binding parameters, stepping through rows, converting SQLite values into Swift types, and serializing access to the underlying connection.

### Opening a Database
Create one ``SQLDatabase`` actor for each SQLite database connection you want to use. Pass a file URL for an on-disk database, or pass `nil` for an in-memory database.

```swift
let database = try SQLDatabase(at: databaseURL)
let memoryDatabase = try SQLDatabase(at: nil)
```

A database actor owns one SQLite connection. Its operations are asynchronous, but SQLite work is run one operation at a time on the connection's internal queue so the underlying handle is not used concurrently.

When you are finished with a connection, call ``SQLDatabase/close()`` to release the SQLite handle before the actor is deallocated.

### Running SQL

Use ``SQLDatabase/execute(_:)`` for SQL that does not need bound parameters or returned rows, such as schema setup.

```swift
try await database.execute("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER
    )
    """)
```

For SQL that includes user data, use a parameterized `execute` overload and write `?` placeholders in the SQL. MinimalSQLite binds each Swift value to the matching placeholder.

```swift
try await database.execute(
    "INSERT INTO users (name, age) VALUES (?, ?)",
    "Ana",
    42
)
```

### Reading Rows

Use typed tuple queries when you know the shape of the result. The expected return type tells MinimalSQLite how to decode each selected column.

```swift
let users: [(Int, String)] = try await database.query(
    "SELECT id, name FROM users WHERE age >= ? ORDER BY name",
    bind: 18
)
```

Use ``SQLDatabase/lookup(_:parameters:)`` for queries that should return zero or one row. It returns `nil` when there is no row and throws if the query returns more than one row.

```swift
let user: (Int, String)? = try await database.lookup(
    "SELECT id, name FROM users WHERE id = ?",
    parameters: [userID]
)
```

Use ``SQLDatabase/queryDict(_:bind:)`` when the selected columns are dynamic or when a dictionary is more convenient than a typed tuple.

```swift
let rows = try await database.queryDict(
    "SELECT id, name, age FROM users ORDER BY name",
    bind: []
)
```

### Binding and Decoding Values

Statement parameters and typed result columns are powered by ``SQLDatabase/Value``. A type that conforms to `Value` knows how to bind itself to a SQLite statement placeholder and how to read itself from a SQLite result column.

MinimalSQLite provides built-in support for common Swift types, including `Int64`, `Int`, `String`, `Bool`, `Double`, `Date`, `Data`, `Null`, and optional wrapped values whose wrapped type also conforms to `Value`.

```swift
let rows: [(Int, String, Date?)] = try await database.query(
    "SELECT id, name, last_seen FROM users",
    parameters: []
)
```

### Transactions

Use ``SQLDatabase/transaction(_:_:)`` to run a group of database operations atomically. If the transaction block completes successfully, MinimalSQLite commits the transaction. If the block throws, MinimalSQLite rolls the transaction back and rethrows the error.

```swift
try await database.transaction(.immediate) {
    try await database.execute(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        "Sam",
        30
    )

    try await database.execute(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        "Lee",
        31
    )
}
```

SQLite `BUSY` and `LOCKED` errors are retried by rerunning the transaction block, so transaction blocks should avoid non-idempotent side effects outside SQLite.

## Topics

### Connections

- ``SQLDatabase``

### Statements

- ``SQLDatabase/execute(_:)``
- ``SQLDatabase/execute(_:parameters:)``
- ``SQLDatabase/lookup(_:parameters:)``
- ``SQLDatabase/query(_:parameters:)``
- ``SQLDatabase/queryDict(_:bind:)``

### Transactions

- ``SQLDatabase/TransactionMode``
- ``SQLDatabase/transaction(_:_:)``

### Values

- ``SQLDatabase/Value``
- ``Null``

