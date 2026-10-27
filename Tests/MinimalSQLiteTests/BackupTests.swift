import Foundation
import Testing
@testable import MinimalSQLite

private actor BackupGate {
    private(set) var reached = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !released else { return }
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CompletionFlag {
    private(set) var value = false
    func complete() { value = true }
}

@Suite("Online backup")
struct BackupTests {
    @Test("Backup includes committed WAL contents and is standalone")
    func includesWriteAheadLog() async throws {
        let sourceURL = temporaryURL("source")
        let destinationURL = temporaryURL("destination")
        defer { removeDatabase(at: sourceURL); removeDatabase(at: destinationURL) }

        let source = try SQLDatabase(at: sourceURL, journalMode: .wal)
        try await source.execute("CREATE TABLE values_table (value TEXT NOT NULL) STRICT")
        try await source.execute("INSERT INTO values_table VALUES (?)", "committed in WAL")
        #expect(FileManager.default.fileExists(atPath: sourceURL.path + "-wal"))

        try await source.backup(to: destinationURL)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path + "-shm"))

        let destination = try SQLDatabase(at: destinationURL, canCreate: false, journalMode: .delete)
        let values: [String] = try await destination.query("SELECT value FROM values_table")
        #expect(values == ["committed in WAL"])
        try await destination.close()
        try await source.close()
    }

    @Test("Readers continue while writers wait for a backup")
    func coordinatesConnections() async throws {
        let sourceURL = temporaryURL("coordinated-source")
        let destinationURL = temporaryURL("coordinated-destination")
        defer { removeDatabase(at: sourceURL); removeDatabase(at: destinationURL) }

        let source = try SQLDatabase(at: sourceURL, journalMode: .wal)
        try await source.execute("CREATE TABLE payloads (id INTEGER PRIMARY KEY, payload BLOB NOT NULL) STRICT")
        try await source.execute("INSERT INTO payloads VALUES (1, ?)", Data(repeating: 0x5a, count: 2 * 1024 * 1024))

        let gate = BackupGate()
        let backup = Task {
            try await source.backup(to: destinationURL, pagesPerStep: 1) {
                await gate.pauseOnce()
            }
        }
        for _ in 0..<10_000 {
            if await gate.reached { break }
            await Task.yield()
        }
        #expect(await gate.reached)

        let count: Int? = try await source.lookup("SELECT COUNT(*) FROM payloads")
        #expect(count == 1)

        let completion = CompletionFlag()
        let writer = Task {
            try await source.execute("INSERT INTO payloads VALUES (2, ?)", Data([1, 2, 3]))
            await completion.complete()
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await completion.value))

        await gate.release()
        try await backup.value
        try await writer.value
        #expect(await completion.value)
        try await source.close()
    }

    @Test("Invalid and cancelled backups leave the source usable")
    func failureCleanup() async throws {
        let sourceURL = temporaryURL("failure-source")
        let existingURL = temporaryURL("existing")
        let cancelledURL = temporaryURL("cancelled")
        let finalURL = temporaryURL("final")
        defer {
            removeDatabase(at: sourceURL); removeDatabase(at: existingURL)
            removeDatabase(at: cancelledURL); removeDatabase(at: finalURL)
        }

        let source = try SQLDatabase(at: sourceURL, journalMode: .wal)
        try await source.execute("CREATE TABLE payloads (payload BLOB NOT NULL) STRICT")
        try await source.execute("INSERT INTO payloads VALUES (?)", Data(repeating: 7, count: 2 * 1024 * 1024))

        await #expect(throws: SQLDatabase.Error.self) {
            try await source.backup(to: sourceURL)
        }
        try Data("keep".utf8).write(to: existingURL)
        await #expect(throws: SQLDatabase.Error.self) {
            try await source.backup(to: existingURL)
        }
        #expect(try Data(contentsOf: existingURL) == Data("keep".utf8))

        let cancelled = Task {
            try await source.backup(to: cancelledURL, pagesPerStep: 1) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))

        let count: Int? = try await source.lookup("SELECT COUNT(*) FROM payloads")
        #expect(count == 1)
        try await source.backup(to: finalURL)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        try await source.close()
    }

    @Test("Cancelling while the destination is locked removes the incomplete copy")
    func lockedDestinationCleanup() async throws {
        let sourceURL = temporaryURL("locked-source")
        let destinationURL = temporaryURL("locked-destination")
        defer { removeDatabase(at: sourceURL); removeDatabase(at: destinationURL) }

        let source = try SQLDatabase(at: sourceURL, journalMode: .wal)
        try await source.execute("CREATE TABLE payloads (payload BLOB NOT NULL) STRICT")
        try await source.execute("INSERT INTO payloads VALUES (?)", Data(repeating: 0x3c, count: 2 * 1024 * 1024))

        let openGate = BackupGate()
        let backup = Task {
            try await source.backup(to: destinationURL, pagesPerStep: 1,
                                    afterOpen: { await openGate.pauseOnce() }, afterStep: {})
        }
        for _ in 0..<10_000 {
            if await openGate.reached { break }
            await Task.yield()
        }
        #expect(await openGate.reached)

        let destination = try SQLDatabase(at: destinationURL, canCreate: false, readers: 0)
        let lockGate = BackupGate()
        let lock = Task {
            try await destination.readwrite { _ in await lockGate.pauseOnce() }
        }
        for _ in 0..<10_000 {
            if await lockGate.reached { break }
            await Task.yield()
        }
        #expect(await lockGate.reached)

        await openGate.release()
        for _ in 0..<100 { await Task.yield() }
        backup.cancel()
        await lockGate.release()
        // The backup is allowed to unlink its incomplete destination before
        // this deliberately conflicting transaction attempts to commit.
        _ = try? await lock.value
        await #expect(throws: CancellationError.self) { try await backup.value }
        try await destination.close()
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))

        let count: Int? = try await source.lookup("SELECT COUNT(*) FROM payloads")
        #expect(count == 1)
        try await source.close()
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "minimal-sqlite-\(name)-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
