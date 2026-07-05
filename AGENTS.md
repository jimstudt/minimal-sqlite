# MinimalSQLite Agent Notes

MinimalSQLite is a small Swift 6.2 SQLite wrapper built for Swift Concurrency. It intentionally stays close to SQLite: callers write SQL directly, while the package handles connection ownership, parameter binding, row decoding, and transaction boundaries.

The public product is the `MinimalSQLite` library. Keep the package small and inspectable; it is not trying to become an ORM.

## Quick Commands

- `swift test` runs the package tests.
- `swift build` builds the library.

## Package Layout

- `Package.swift` defines the `MinimalSQLite` library product and test target.
- `Sources/MinimalSQLite/Connection.swift` defines the `SQLDatabase` actor, SQLite handle opening/closing, writer/reader pools, and retrying `readwrite`/`readonly` transaction entry points.
- `Sources/MinimalSQLite/Transaction.swift` defines `TransactionBeginMode`, the `Transaction` protocol, `ReadTransaction`, and `WriteTransaction`.
- `Sources/MinimalSQLite/Statement.swift` owns prepared statement glue and the public execute/query/lookup/queryDict APIs.
- `Sources/MinimalSQLite/Value.swift` defines `SQLDatabase.Value` plus built-in Swift-to-SQLite conversions.
- `Sources/MinimalSQLite/AsyncTokenPool.swift` is an internal actor that lends writer/reader connection tokens to one operation at a time.
- `Sources/CSQLite3/` is the Linux-only system-library shim for SQLite.
- `Sources/MinimalSQLite/MinimalSQLite.docc/` contains DocC API documentation.
- `Tests/MinimalSQLiteTests/` contains behavioral tests for opening databases, executing statements, transactions, readers during writes, strict typing, and dictionary queries.

## Core Model

- `SQLDatabase` owns one writer connection and a pool of readonly connections.
- `readwrite` uses `BEGIN IMMEDIATE`.
- `readonly` uses `BEGIN DEFERRED`.
- `ReadTransaction` intentionally exposes query APIs but no execute API, so accidental writes are rejected at compile time.
- `WriteTransaction` exposes both query and execute APIs.
- Convenience `SQLDatabase.execute` methods run one-off write transactions.
- Convenience `SQLDatabase.query`, `lookup`, and `queryDict` methods run one-off read transactions.
- `lookup` is for zero-or-one-row queries and throws when more than one row is returned.

## Retry And Side Effects

`readwrite` and `readonly` retry when SQLite returns `BUSY` or `LOCKED`. A retry reruns the whole transaction block.

Because of that, transaction blocks must avoid non-idempotent side effects outside SQLite. Keep logging, network calls, file writes, cache mutation, and notifications outside the transaction block unless repeating them is harmless.

## Row Reading

Typed tuple queries depend on selected column order matching the expected tuple type:

```swift
let rows: [(Int, String)] = try await database.query(
    "SELECT id, name FROM users ORDER BY name"
)
```

Use `queryDict` only when the selected columns are dynamic or a dictionary is genuinely clearer. Prefer typed tuples for normal model code because they make the expected result shape visible.

## Value Conversion

`SQLDatabase.Value` is the conversion seam for bound parameters and typed row decoding.

Built-in conformances currently include:

- `RowID`
- `Int64`
- `Int`
- `String`
- `Bool`
- `Double`
- `Date`
- `Data`
- `Null`
- `Optional<Wrapped>` when `Wrapped: Value`

Existing `Date` behavior is part of the public contract: it reads integer epoch values or ISO 8601 text, and binds dates as integer Unix epochs. Do not break this behavior for existing users.

For Femtoblogger-style text timestamps, use `SQLiteDateString<Format>` with an explicit `SQLiteDateStringFormat` rather than changing `Date` globally.

## Femtoblogger Branch Work

This checkout is on branch `femtoblogger` for coordinated work with `/Users/jim/coding/femtoblogger`.

Femtoblogger will use this package through a local SwiftPM path dependency:

```swift
.package(path: "../minimal-sqlite")
```

Additive APIs added for the FemtobloggerDB migration:

- `RowID`, a small value type for SQLite `rowid` and row-id-like integer values.
- Writer metadata helpers: `lastInsertRowID`, `changes`, and `totalChanges`.
- `SQLiteDateString<Format>` plus `SQLiteDateStringFormat` for legacy timestamp columns such as `yyyy-MM-dd HH:mm:ss`.

All MinimalSQLite API changes should remain source-compatible because other projects use this package.

## Editing Guidance

- Prefer small, inspectable additions over broad abstractions.
- Keep SQLite concepts visible.
- Avoid ORM-like mapping layers.
- Add tests for every new public API.
- Update DocC and `README.md` when public API changes.
- Avoid introducing dependency weight.
- Keep Linux support in mind: macOS imports `SQLite3` directly, while Linux uses the `CSQLite3` system-library target.

## Known Rough Edges

- Existing DocC notes mention Xcode confusion around `ReadTransaction`; verify DocC rendering after public API changes.
