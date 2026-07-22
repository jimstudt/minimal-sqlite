# MinimalSQLite

Use SQLite from Swift with a small async API for connections, statements, values, and read-only or read-write transactions.

## Overview

MinimalSQLite is a lightweight wrapper around SQLite's C API. It keeps SQLite handles behind a ``SQLDatabase`` actor, then exposes async methods for running SQL, binding Swift values, decoding rows, and grouping work in transactions.

The package is intentionally close to SQLite. You still write SQL directly, choose your schema, and decide which queries to run. MinimalSQLite handles the repetitive glue: opening and closing the database, preparing statements, binding parameters, stepping through rows, converting SQLite values into Swift types, and lending connections to one operation at a time.

### Opening a Database

Create one ``SQLDatabase`` actor for each SQLite database you want to use. Pass a file URL for an on-disk database, or pass `nil` for a shared in-memory database.

```swift
let database = try SQLDatabase(at: databaseURL, journalMode: .wal)
let memoryDatabase = try SQLDatabase(at: nil)
```

A database owns one writer connection and a pool of reader connections. Read-write transactions are serialized through the single writer connection. Read-only transactions borrow connections from the reader pool, allowing several reads to run at once up to the configured pool size, which defaults to 4. Foreign-key enforcement is enabled by default on all connections.

For journal modes that must be selected outside a transaction, pass
`journalMode` while opening the database. MinimalSQLite configures and verifies
the mode on the writer before it opens any reader connections.

When you are finished with a database, call ``SQLDatabase/close()`` to release the SQLite handles before the actor is deallocated.

### Transactions First

Use ``SQLDatabase/readwrite(_:)`` when work may modify the database. The block receives a ``WriteTransaction``, which exposes both query APIs and `execute` APIs.

```swift
try await database.readwrite { transaction in
    try await transaction.execute("""
        CREATE TABLE users (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            age INTEGER
        )
        """)

    try await transaction.execute(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        "Ana",
        42
    )
}
```

Use ``SQLDatabase/readonly(_:)`` when work should only read. The block receives a ``ReadTransaction``, which exposes query APIs but not `execute` APIs, so accidental writes are rejected at compile time.

```swift
let users: [(Int, String)] = try await database.readonly { transaction in
    try await transaction.query(
        "SELECT id, name FROM users WHERE age >= ? ORDER BY name",
        bind: 18
    )
}
```

If a transaction block throws, MinimalSQLite rolls the transaction back and rethrows the error. SQLite `BUSY` and `LOCKED` errors are retried by rerunning the transaction block, so transaction blocks should avoid non-idempotent side effects outside SQLite.

### Convenience Statements

For simple one-off work, ``SQLDatabase`` also provides direct statement methods. These are convenience wrappers: `execute` runs in a one-off read-write transaction, while `lookup`, `query`, and `queryDict` run in one-off read-only transactions.

```swift
try await database.execute(
    "INSERT INTO users (name, age) VALUES (?, ?)",
    "Sam",
    30
)

let rows: [(Int, String)] = try await database.query(
    "SELECT id, name FROM users ORDER BY name"
)
```

Prefer explicit ``SQLDatabase/readwrite(_:)`` or ``SQLDatabase/readonly(_:)`` blocks when several statements should share one transaction or when you want the transaction boundary to be obvious.

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

Use `queryDict(_:bind:)` when the selected columns are dynamic or when a dictionary is more convenient than a typed tuple. Pass an array of ``SQLDatabase/Value`` values when the parameters are already collected.

```swift
let minimumAge = 18
let maximumAge = 65
let values: [any SQLDatabase.Value] = [minimumAge, maximumAge]
let rows = try await database.queryDict(
    "SELECT id, name, age FROM users WHERE age BETWEEN ? AND ? ORDER BY name",
    bind: values
)
```

For fixed call sites, use the argument pack overload to pass bound values inline.

```swift
let rows = try await database.queryDict(
    "SELECT id, name, age FROM users WHERE age BETWEEN ? AND ? ORDER BY name",
    bind: 18,
    65
)
```

### Binding and Decoding Values

Statement parameters and typed result columns are powered by ``SQLDatabase/Value``. A type that conforms to `Value` knows how to bind itself to a SQLite statement placeholder and how to read itself from a SQLite result column.

MinimalSQLite provides built-in support for common Swift types, including `Int64`, `Int`, `String`, `Bool`, `Double`, `Date`, `Data`, `Null`, and optional wrapped values whose wrapped type also conforms to `Value`.

```swift
let rows: [(Int, String, Date?)] = try await database.query(
    "SELECT id, name, last_seen FROM users"
)
```

Use ``RowID`` when you want to make SQLite rowid values explicit in your model code.

```swift
let rows: [(RowID, String)] = try await database.query(
    "SELECT rowid, name FROM users"
)
```

The built-in `Date` conformance preserves its original behavior: it reads integer Unix epochs or ISO 8601 text and binds dates as integer Unix epochs. For legacy schemas that store dates as formatted SQLite text, define a ``SQLiteDateStringFormat`` and use ``SQLiteDateString``.

```swift
enum TimestampFormat: SQLiteDateStringFormat {
    static func parse(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

typealias Timestamp = SQLiteDateString<TimestampFormat>
```

### Writer Metadata

Inside a ``WriteTransaction``, use ``WriteTransaction/lastInsertRowID()``, ``WriteTransaction/changes()``, and ``WriteTransaction/totalChanges()`` when SQLite write metadata is needed.

## Topics

### Connections

- ``SQLDatabase``

### Transactions

- ``ReadTransaction``
- ``WriteTransaction``
- ``SQLDatabase/readonly(_:)``
- ``SQLDatabase/readwrite(_:)``

### Statements

- ``SQLDatabase/execute(_:)``
- ``SQLDatabase/execute(_:parameters:)``
- ``SQLDatabase/lookup(_:parameters:)``
- ``SQLDatabase/query(_:parameters:)``
- ``SQLDatabase/queryDict(_:)``

### Values

- ``SQLDatabase/Value``
- ``RowID``
- ``Null``
- ``SQLiteDateString``
- ``SQLiteDateStringFormat``
