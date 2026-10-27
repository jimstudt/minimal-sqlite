# MinimalSQLite

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2026%2B%20%7C%20Linux-lightgrey)](https://github.com/jimstudt/minimal-sqlite)
[![Documentation](https://img.shields.io/badge/DocC-Documentation-0A84FF)](https://jimstudt.github.io/minimal-sqlite/documentation/minimalsqlite/)
[![Documentation workflow](https://github.com/jimstudt/minimal-sqlite/actions/workflows/documentation.yml/badge.svg)](https://github.com/jimstudt/minimal-sqlite/actions/workflows/documentation.yml)

MinimalSQLite is a tiny Swift 6.2 SQLite wrapper built for Swift Concurrency.

It intentionally stays close to SQLite: you write SQL directly, choose your own schema, and keep SQLite's transaction model visible. The package handles the repetitive parts around connection ownership, prepared statements, parameter binding, row decoding, and retryable read/write transaction boundaries.

This is not an ORM. It is meant to be small, readable, and boring in the best way.

## Features

- `SQLDatabase` actor owns SQLite connections.
- One writer connection plus a pool of read-only connections.
- Optional journal-mode configuration before reader connections are opened.
- Explicit `readwrite` and `readonly` transaction APIs.
- Read-only transactions do not expose `execute`, so accidental writes are rejected at compile time.
- Convenience `execute`, `query`, `lookup`, and `queryDict` helpers for one-off operations.
- Typed tuple row decoding for common fixed-shape queries.
- Bound parameters through Swift values.
- Built-in support for common SQLite value types.
- Small `RowID` type for hidden SQLite rowids and row-id-like integer keys.
- Writer metadata helpers: `lastInsertRowID()`, `changes()`, and `totalChanges()`.
- Online backups of open databases, including committed WAL contents.
- Optional formatted text-date wrapper for legacy timestamp columns.

## Requirements

- Swift 6.2 or newer.
- macOS 26 or newer for the declared Apple platform.
- SQLite 3.
- On Linux, install SQLite development headers, for example `libsqlite3-dev` on Debian/Ubuntu.

## Installation

Add MinimalSQLite to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/jimstudt/minimal-sqlite.git", from: "0.1.6")
]
```

Then add the product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MinimalSQLite", package: "minimal-sqlite")
    ]
)
```

## Quick Start

```swift
import Foundation
import MinimalSQLite

let databaseURL = URL(fileURLWithPath: "/tmp/example.sqlite")
let db = try SQLDatabase(at: databaseURL, journalMode: .wal)

try await db.execute("""
    CREATE TABLE IF NOT EXISTS names (
        first TEXT NOT NULL,
        last TEXT NOT NULL
    )
    """)

try await db.execute(
    "INSERT INTO names (first, last) VALUES (?, ?)",
    "Arthur",
    "Dent"
)

let rows: [(RowID, String, String)] = try await db.query(
    "SELECT rowid, first, last FROM names ORDER BY rowid"
)

for (rowid, first, last) in rows {
    print("\(rowid.rawValue): \(first) \(last)")
}
```

## Transactions

Use `readwrite` for work that can modify the database. It uses `BEGIN IMMEDIATE`.

```swift
let insertedID = try await db.readwrite { tx in
    try await tx.execute(
        "INSERT INTO names (first, last) VALUES (?, ?)",
        "Ford",
        "Prefect"
    )

    return await tx.lastInsertRowID()
}
```

Use `readonly` for work that should not write. It uses `BEGIN DEFERRED`.

```swift
let count: Int? = try await db.readonly { tx in
    try await tx.lookup("SELECT count(*) FROM names")
}
```

SQLite `BUSY` and `LOCKED` errors are retried by rerunning the transaction block. Because of that, transaction bodies should avoid non-idempotent side effects outside SQLite, such as network calls, file writes, notifications, or cache mutation.

Journal modes such as WAL must be selected while opening the database, before
MinimalSQLite opens its reader pool and before a transaction begins:

```swift
let db = try SQLDatabase(at: databaseURL, journalMode: .wal)
```

MinimalSQLite verifies the mode SQLite actually selected. Requesting a mode
that SQLite cannot activate throws `SQLDatabase.Error.journalModeUnavailable`.

## Query Shapes

Use typed tuples for fixed result shapes:

```swift
let names: [(String, String)] = try await db.query(
    "SELECT first, last FROM names ORDER BY last, first"
)
```

The selected column order must match the expected tuple type.

Use `lookup` for zero-or-one-row queries:

```swift
let name: (String, String)? = try await db.lookup(
    "SELECT first, last FROM names WHERE rowid = ?",
    parameters: [RowID(1)]
)
```

`lookup` returns `nil` when no row exists and throws if the query returns more than one row.

Use `queryDict` when the selected columns are dynamic or dictionary-shaped rows are clearer:

```swift
let rows = try await db.queryDict(
    "SELECT rowid, first, last FROM names"
)
```

## Values

Statement parameters and typed result columns use `SQLDatabase.Value`.

Built-in value conversions include:

- `Int64`
- `Int`
- `String`
- `Bool`
- `Double`
- `Date`
- `Data`
- `Null`
- `Optional<Wrapped>` when `Wrapped` conforms to `SQLDatabase.Value`
- `RowID`
- `SQLiteDateString<Format>`

`Date` keeps its original behavior: it reads integer Unix epoch values or ISO 8601 text, and binds as an integer Unix epoch.

For legacy schemas that store formatted text timestamps, define an explicit format:

```swift
enum LegacyTimestampFormat: SQLiteDateStringFormat {
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

typealias LegacyTimestamp = SQLiteDateString<LegacyTimestampFormat>

let rows: [(LegacyTimestamp, String)] = try await db.query(
    "SELECT posted, title FROM articles ORDER BY posted DESC"
)
```

## Row IDs And Write Metadata

Use `RowID` when selecting SQLite's hidden `rowid`, an explicit integer primary key, or `lastInsertRowID()`:

```swift
let id = try await db.readwrite { tx in
    try await tx.execute("INSERT INTO names (first, last) VALUES (?, ?)", "Zaphod", "Beeblebrox")
    return await tx.lastInsertRowID()
}
```

Inside a `WriteTransaction`, these metadata helpers are available:

- `lastInsertRowID() -> RowID`
- `changes() -> Int`
- `totalChanges() -> Int`

## Online Backups

Create a standalone copy of an open database with `backup(to:)`:

```swift
let snapshotURL = temporaryDirectory.appending(path: "snapshot.sqlite3")
try await db.backup(to: snapshotURL)
```

The destination must not already exist. The backup includes committed changes
that have not yet been checkpointed from a WAL. MinimalSQLite temporarily
reserves the writer connection while copying in bounded batches, while existing
readers may continue. To replace a user-facing file atomically, back up to a
temporary URL and move the completed file into place after this call returns.

## Commands

Build the package:

```sh
swift build
```

Run tests:

```sh
swift test
```

## Design Notes

MinimalSQLite is deliberately small:

- No ORM layer.
- No migrations framework.
- No query builder.
- No hidden model mapping.
- No dependency weight beyond SQLite itself.

The goal is a straightforward Swift Concurrency wrapper around SQLite for projects that are comfortable writing SQL directly.
