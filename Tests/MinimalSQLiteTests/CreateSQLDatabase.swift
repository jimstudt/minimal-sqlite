//
//  CreateSQLDatabase.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//

import Foundation
import Testing
@testable import MinimalSQLite

let schema : String = """
    create table names (
        first TEXT NOT NULL,
        last TEXT NOT NULL
    ) STRICT;
    create table primes (
        number INTEGER NOT NULL,
        position INTEGER NOT NULL
    ) STRICT;
    """

enum TestTimestampFormat: SQLiteDateStringFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

typealias TestTimestamp = SQLiteDateString<TestTimestampFormat>

@Suite("CreateSQLDatabase")
struct CreateSQLDatabaseTests {
    @Test("Open in memory")
    func openInMemory() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)
        
        await #expect(throws: Never.self) {
            try await db.close()
        }
    }

    @Test("Configure WAL before opening reader connections")
    func configureWriteAheadLogging() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimal-sqlite-wal-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let db: MinimalSQLite.SQLDatabase
        do {
            db = try MinimalSQLite.SQLDatabase(at: url, journalMode: .wal)
        } catch {
            Issue.record("Could not open WAL database at \(url.path): \(error)")
            return
        }
        try await db.execute("CREATE TABLE wal_test (value TEXT NOT NULL)")
        let configuredModes: [String] = try await db.query("PRAGMA journal_mode")
        #expect(configuredModes.map { $0.lowercased() } == ["wal"])
        try await db.close()

        let reopened: MinimalSQLite.SQLDatabase
        do {
            reopened = try MinimalSQLite.SQLDatabase(at: url)
        } catch {
            Issue.record("Could not reopen WAL database at \(url.path): \(error)")
            return
        }
        let persistedModes: [String] = try await reopened.query("PRAGMA journal_mode")
        #expect(persistedModes.map { $0.lowercased() } == ["wal"])
        try await reopened.close()
    }
    
    @Test("Create Table in memory")
    func createTableInMemory() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
        }

        await #expect(throws: Never.self) {
            try await db.close()
        }
    }

    @Test("Execute with Parameters")
    func executeWithParameters() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["Arthur", "Dent"])
            try await db.close()
        }
    }

    @Test("Static Query")
    func staticQuery() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["Arthur", "Dent"])
            let rows : [(String,String)] = try await db.query("select first,last from names")
            #expect(rows.count == 1)
            #expect(rows.first?.0 == "Arthur")
            #expect(rows.first?.1 == "Dent")
            try await db.close()
        }
    }

    @Test("Parameter Query")
    func parameterQuery() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["Arthur", "Dent"])
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["DentArthur", "ArthurDent"])

            let rows : [(String,String)] = try await db.query("select first,last from names where last = ?", bind: "Dent")
            #expect(rows.count == 1)
            #expect(rows.first?.0 == "Arthur")
            #expect(rows.first?.1 == "Dent")
            try await db.close()
        }
    }

    @Test("Transaction simple inserts")
    func transactionInserts() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

       await #expect(throws: Never.self) {
            try await db.execute(schema)
            let status = try await db.readwrite { tx in
                try await tx.execute("insert into names (first, last) values (?, ?)", parameters: ["Ford", "Prefect"])
                try await tx.execute("insert into names (first, last) values (?, ?)", parameters: ["Tricia", "McMillan"])
                return "great!"
            }
            #expect(status == "great!")
            let rows: [(String, String)] = try await db.query("select first, last from names order by last, first")
            #expect(rows.count == 2)
            #expect(rows[0].0 == "Tricia" && rows[0].1 == "McMillan")
            #expect(rows[1].0 == "Ford" && rows[1].1 == "Prefect")
            try await db.close()
        }
    }

    @Test("STRICT rejects non-text in TEXT columns")
    func strictRejectsWrongType() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into primes (number, position) values (?, ?)", parameters: [2, 1])
            try await db.execute("insert into primes (number, position) values (?, ?)", parameters: [3, 2])

        }

        // Attempt to insert an TEXT into a INTEGER column should fail under STRICT
        await #expect(throws: MinimalSQLite.SQLDatabase.Error.self) {
            try await db.execute("insert into primes (number, position) values (?, ?)", parameters: [5, "Third"])
        }

        await #expect(throws: Never.self) {
            try await db.close()
        }
    }

    @Test("Reader sees old value during open writer transaction")
    func readerSeesOldValueDuringOpenWriterTransaction() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimal-sqlite-lock-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try MinimalSQLite.SQLDatabase(at: url)

        await #expect(throws: Never.self) {
            try await db.execute("""
                create table lock_test (
                    id INTEGER PRIMARY KEY,
                    value TEXT NOT NULL
                ) STRICT;
                """)
            try await db.execute(
                "insert into lock_test (id, value) values (?, ?)",
                1,
                "old"
            )

            async let writer: Void = db.readwrite { tx in
                try await tx.execute(
                    "update lock_test set value = ? where id = ?",
                    "new",
                    1
                )
                try await Task.sleep(for: .seconds(1))
            }

            async let readerValue: String? = {
                try await Task.sleep(for: .milliseconds(500))
                return try await db.readonly { tx -> String? in
                    let row: (String)? = try await tx.lookup(
                        "select value from lock_test where id = ?",
                        parameters: [1]
                    )
                    return row
                }
            }()

            let valueDuringWrite = try await readerValue
            #expect(valueDuringWrite == "old")

            try await writer

            let valueAfterCommit: (String)? = try await db.lookup(
                "select value from lock_test where id = ?",
                parameters: [1]
            )
            #expect(valueAfterCommit == "new")

            try await db.close()
        }
    }

    @Test("queryDict returns dictionaries keyed by column name")
    func queryDictTest() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)
        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["Arthur", "Dent"])
            try await db.execute("insert into names (first, last) values (?, ?)", parameters: ["Ford", "Prefect"])

            let rows = try await db.queryDict("select first, last from names where last = ?", bind: "Dent")
            #expect(rows.count == 1)
            if let row = rows.first {
                let first = row["first"] as? String
                let last = row["last"] as? String
                #expect(first == "Arthur")
                #expect(last == "Dent")
            } else {
                Issue.record("Expected at least one row from queryDict")
            }

            try await db.close()
        }
    }

    @Test("RowID reads hidden rowids")
    func rowIDReadsHiddenRowids() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)
            try await db.execute("insert into names (first, last) values (?, ?)", "Zaphod", "Beeblebrox")

            let rows: [(RowID, String)] = try await db.query(
                "select rowid, first from names"
            )

            #expect(rows.count == 1)
            #expect(rows[0].0.intValue == 1)
            #expect(rows[0].1 == "Zaphod")
            try await db.close()
        }
    }

    @Test("Write transaction exposes row and change metadata")
    func writeTransactionMetadata() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute(schema)

            let metadata = try await db.readwrite { tx in
                try await tx.execute("insert into names (first, last) values (?, ?)", "Marvin", "Android")
                let inserted = await tx.lastInsertRowID()
                let insertChanges = await tx.changes()

                try await tx.execute("update names set last = ? where rowid = ?", "Paranoid Android", inserted)
                let updateChanges = await tx.changes()
                let total = await tx.totalChanges()

                return (inserted, insertChanges, updateChanges, total)
            }

            #expect(metadata.0.intValue == 1)
            #expect(metadata.1 == 1)
            #expect(metadata.2 == 1)
            #expect(metadata.3 == 2)
            try await db.close()
        }
    }

    @Test("SQLiteDateString stores formatted text dates")
    func sqliteDateStringStoresFormattedTextDates() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute("""
                create table events (
                    name TEXT NOT NULL,
                    happened TEXT,
                    optional_happened TEXT
                ) STRICT;
                """)

            let date = TestTimestampFormat.parse("2026-07-04 22:32:00")!
            try await db.execute(
                "insert into events (name, happened, optional_happened) values (?, ?, ?)",
                "copied-db",
                TestTimestamp(date),
                Optional<TestTimestamp>.none
            )

            let row: (String, TestTimestamp, TestTimestamp?)? = try await db.lookup(
                "select name, happened, optional_happened from events"
            )

            let found = try #require(row)
            #expect(found.0 == "copied-db")
            #expect(TestTimestampFormat.string(from: found.1.date) == "2026-07-04 22:32:00")
            #expect(found.2 == nil)
            try await db.close()
        }
    }

    @Test("SQLiteDateString throws on invalid formatted dates")
    func sqliteDateStringThrowsOnInvalidDateText() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)

        await #expect(throws: Never.self) {
            try await db.execute("""
                create table events (
                    happened TEXT NOT NULL
                ) STRICT;
                """)
            try await db.execute("insert into events (happened) values (?)", "not-a-date")
        }

        await #expect(throws: MinimalSQLite.SQLDatabase.Error.self) {
            let _: [(TestTimestamp)] = try await db.query("select happened from events")
        }

        await #expect(throws: Never.self) {
            try await db.close()
        }
    }
}
