# MinimalSQLite - a tiny Swift Concurrency friendly SQLite package

This is my tiny SQLite package. It works well in a Swift Concurrency environment, keeps SQLite concepts visible, and stays small enough to inspect.

## Example

It goes about like this to use it:

```swift
let db = try MinimalSQLite.SQLDatabase(at: yourDatabaseURL)

try await db.readwrite { tx in
    try await tx.execute(
        "INSERT INTO names (first, last) VALUES (?, ?)",
        "Arthur",
        "Dent"
    )
}

let rows: [(MinimalSQLite.RowID, String, String)] = try await db.query(
    "SELECT rowid, first, last FROM names"
)
```

Use `readwrite` for modifying work and `readonly` for read-only work that should share a transaction. Convenience `execute`, `query`, `lookup`, and `queryDict` methods are available on `SQLDatabase` for one-off operations.

## Values

Built-in value conversions include `Int64`, `Int`, `String`, `Bool`, `Double`, `Date`, `Data`, `Null`, `Optional`, and `RowID`.

`Date` keeps its original behavior: it reads integer epoch values or ISO 8601 text and binds as an integer Unix epoch. For legacy SQLite text timestamps, define an explicit `SQLiteDateStringFormat` and use `SQLiteDateString<YourFormat>`.

## Writer Metadata

Inside a `WriteTransaction`, use:

- `lastInsertRowID()`
- `changes()`
- `totalChanges()`

## TODO

- The docc docs are not working right in Xcode around the ReadTransaction functions.  Looks like it is getting some other ReadTransaction somewhere else.
