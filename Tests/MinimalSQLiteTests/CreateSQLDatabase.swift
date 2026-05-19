//
//  CreateSQLDatabase.swift
//  Mailecule
//
//  Created by Jim Studt on 2/18/26.
//

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

@Suite("CreateSQLDatabase")
struct CreateSQLDatabaseTests {
    @Test("Open in memory")
    func openInMemory() async throws {
        let db = try MinimalSQLite.SQLDatabase(at: nil)
        
        await #expect(throws: Never.self) {
            try await db.close()
        }
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
}

