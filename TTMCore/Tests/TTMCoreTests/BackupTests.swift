import XCTest
import GRDB
@testable import TTMCore

/// Backup & restore (docs/plans/DATA_PORTABILITY_PLAN.md): the file IS the
/// database, restore replaces everything, and nothing touches the live store
/// until validation passes. These tests are where the real guarantees live —
/// the app layer above is only pickers.
final class BackupTests: XCTestCase {
    private struct C: Clock { func now() -> UnixTime { 1_700_000_000 } }

    private final class Secrets: SecretStore, @unchecked Sendable {
        func read(ref: String) throws -> String? { nil }
        func write(_ value: String, ref: String) throws {}
        func delete(ref: String) throws {}
    }
    private struct Net: NetworkClient {
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { Data() }
        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { Data() }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func core(at name: String) throws -> LocalCore {
        try LocalCore(dbPath: path(name), secrets: Secrets(), network: Net(), clock: C())
    }

    /// Data spread across the tables a backup must carry.
    @discardableResult
    private func seed(_ store: Store, txnCount: Int = 3) throws -> Store {
        try DefaultData.seedIfEmpty(store, now: C().now())
        try store.saveConnection(ConnectionRecord(id: "c", name: "conn", keychainRef: "ref", sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: 1))
        try store.saveAccount(AccountRecord(id: "a", connectionId: "c", sfinAccountId: "sa", name: "Checking",
            nickname: "Everyday", currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil,
            balanceCents: 12_345, availableCents: nil, balanceDate: 100, archived: false, createdAt: 1))
        for i in 0..<txnCount {
            try store.saveTransaction(TransactionRecord(
                id: "t\(i)", accountId: "a", sfinTxnId: "t\(i)", postedAt: UnixTime(100 + i),
                transactedAt: nil, amountCents: -500, description: "COFFEE \(i)", payee: nil,
                memo: nil, pending: false, categoryId: "dining", categorySource: "manual",
                isTransfer: false, transferGroupId: nil, extraJson: nil, createdAt: 1, updatedAt: 1))
        }
        return store
    }

    /// Every row of every real table, for round-trip comparison.
    private func dump(_ dbPath: String) throws -> [String: [[String: String]]] {
        // Read-write: a cleanly-closed WAL database has no -shm, and SQLite
        // won't open one read-only without it.
        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        return try queue.read { conn in
            var out: [String: [[String: String]]] = [:]
            for table in BackupManager.requiredTables where table != "grdb_migrations" {
                let rows = try Row.fetchAll(conn, sql: "SELECT * FROM \(table)")
                out[table] = rows.map { row in
                    var dict: [String: String] = [:]
                    for (column, value) in row { dict[column] = String(describing: value) }
                    return dict
                }
            }
            return out
        }
    }

    // MARK: Export

    func testExportProducesValidWALFreeSnapshot() async throws {
        let core = try core(at: "live.db")
        try seed(core.store)
        let url = try await core.exportBackup()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, BackupManager.fileExtension)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // VACUUM INTO leaves no sidecars: the backup is a single file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))

        // Inspect doubles as the integrity check (quick_check + table set).
        let info = try await core.inspectBackup(at: url)
        XCTAssertEqual(info.accounts, 1)
        XCTAssertEqual(info.transactions, 3)
        XCTAssertEqual(info.newestTransactionAt, 102)
        XCTAssertGreaterThan(info.fileSizeBytes, 0)
        XCTAssertEqual(info.migrations, Database.knownMigrations)
        XCTAssertFalse(info.needsMigration)
    }

    func testExportOverwritesAnExistingFile() async throws {
        let core = try core(at: "live.db")
        try seed(core.store)
        let dest = dir.appendingPathComponent("out.ttmbackup")
        try Data("stale bytes".utf8).write(to: dest)

        try BackupManager.export(from: Database(path: path("live.db")), to: dest)
        let info = try await core.inspectBackup(at: dest)
        XCTAssertEqual(info.transactions, 3)
    }

    // MARK: Round trip

    func testRoundTripPreservesEveryTable() async throws {
        let source = try core(at: "source.db")
        try seed(source.store, txnCount: 5)
        let propertyId = try await source.addProperty(name: "House", kind: "real_estate")
        try await source.addPropertyValue(propertyId: propertyId, value: Money(cents: 500_000), asOf: 90, note: "est")
        let before = try dump(path("source.db"))
        let backup = try await source.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }

        // A different store, with its own (seeded-empty) contents.
        let target = try core(at: "target.db")
        let emptyCount = try await target.transactions(TxnQuery()).count
        XCTAssertEqual(emptyCount, 0)

        let info = try await target.restoreBackup(from: backup)
        XCTAssertEqual(info.transactions, 5)

        // Row-for-row equality across every real table.
        XCTAssertEqual(try dump(path("target.db")), before)
        // …and the facade reads through the rebuilt internals.
        let txns = try await target.transactions(TxnQuery()).count
        XCTAssertEqual(txns, 5)
        let accountName = try await target.accounts().first?.name
        XCTAssertEqual(accountName, "Everyday")
        let properties = try await target.properties().count
        XCTAssertEqual(properties, 1)
    }

    func testRestoredStoreIsWritableAndSearchable() async throws {
        let source = try core(at: "source.db")
        try seed(source.store)
        let backup = try await source.exportBackup()
        let target = try core(at: "target.db")
        try await target.restoreBackup(from: backup)

        // FTS survived the copy (it's an ordinary table inside the file).
        let hits = try await target.transactions(TxnQuery(searchText: "COFFEE")).count
        XCTAssertEqual(hits, 3)

        // The rebuilt internals write to the NEW file, not the replaced one.
        try await target.setAccountClass(accountId: "a", accountClass: .investment)
        let cls = try await target.accounts().first?.accountClass
        XCTAssertEqual(cls, .investment)
        XCTAssertEqual(try scalar("SELECT class FROM accounts WHERE id = 'a'", at: path("target.db")), "investment")
    }

    // MARK: Schema compatibility

    func testOlderBackupIsMigratedForwardOnRestore() async throws {
        // A file stopped at v1: no FTS, no nickname column, no partial index.
        let oldPath = path("old.db")
        let queue = try DatabaseQueue(path: oldPath)
        try Database.migrator(through: "v1_schema").migrate(queue)
        try queue.close()

        let info = try BackupManager.inspect(at: URL(fileURLWithPath: oldPath))
        XCTAssertEqual(info.migrations, ["v1_schema"])
        XCTAssertTrue(info.needsMigration)

        let target = try core(at: "target.db")
        try await target.restoreBackup(from: URL(fileURLWithPath: oldPath))

        // Reopening ran v2…v4, so the current schema is fully present.
        XCTAssertEqual(try appliedMigrations(path("target.db")), Set(Database.knownMigrations))
        // v3's column exists (this would be an SQL error against the v1 file)…
        try await target.renameAccount(accountId: "missing", name: "ignored")
        // …and v2's FTS table is queryable.
        let hits = try await target.transactions(TxnQuery(searchText: "anything")).count
        XCTAssertEqual(hits, 0)
    }

    func testBackupFromNewerAppIsRefused() async throws {
        let core = try core(at: "live.db")
        try seed(core.store)
        let backup = try await core.exportBackup()
        // Simulate a future release having migrated the file.
        try execute("INSERT INTO grdb_migrations (identifier) VALUES ('v99_from_the_future')", at: backup.path)

        XCTAssertThrowsError(try BackupManager.inspect(at: backup)) { error in
            guard case .needsNewerApp(let ids) = error as? BackupError else {
                return XCTFail("expected needsNewerApp, got \(error)")
            }
            XCTAssertEqual(ids, ["v99_from_the_future"])
        }
    }

    func testAcceptsACleanlyClosedStoreStillInWALMode() async throws {
        // Not one of our exports: a raw ttm.db lifted from an app container. It
        // carries journal_mode=WAL in its header, and with no -shm alongside it
        // SQLite refuses a read-only open — the private-copy fallback covers it.
        let sourcePath = path("hand.db")
        let source = try Database(path: sourcePath)
        try seed(Store(source), txnCount: 4)
        try source.close()                       // checkpoints and drops the -wal

        let handCopied = dir.appendingPathComponent("ttm-copy.ttmbackup")
        try FileManager.default.copyItem(atPath: sourcePath, toPath: handCopied.path)

        let info = try BackupManager.inspect(at: handCopied)
        XCTAssertEqual(info.transactions, 4)

        // …and it restores like any other backup.
        let target = try core(at: "target.db")
        try await target.restoreBackup(from: handCopied)
        let count = try await target.transactions(TxnQuery()).count
        XCTAssertEqual(count, 4)
    }

    func testRejectsACopyTakenWhileTheStoreWasOpen() async throws {
        // Copying ttm.db out from under a running app leaves its content behind
        // in the -wal. Better to refuse than to restore a store that looks empty.
        let source = try core(at: "source.db")
        try seed(source.store, txnCount: 4)      // still open: uncheckpointed
        let torn = dir.appendingPathComponent("torn.ttmbackup")
        try FileManager.default.copyItem(atPath: path("source.db"), toPath: torn.path)

        assertNotABackup(torn)
    }

    // MARK: Rejection

    func testRejectsGarbageAndForeignDatabases() throws {
        let notSQLite = dir.appendingPathComponent("notes.txt")
        try Data("hello, not a database".utf8).write(to: notSQLite)
        assertNotABackup(notSQLite)

        let empty = dir.appendingPathComponent("empty.ttmbackup")
        try Data().write(to: empty)
        assertNotABackup(empty)

        // Valid SQLite, wrong schema — the case a magic-header check alone misses.
        let foreign = dir.appendingPathComponent("someone-elses.db")
        let q = try DatabaseQueue(path: foreign.path)
        try q.write { try $0.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)") }
        try q.close()
        assertNotABackup(foreign)

        XCTAssertThrowsError(try BackupManager.inspect(at: dir.appendingPathComponent("nope.ttmbackup")))
    }

    func testRejectionLeavesTheLiveStoreUntouched() async throws {
        let core = try core(at: "live.db")
        try seed(core.store)
        let junk = dir.appendingPathComponent("junk.ttmbackup")
        try Data("garbage".utf8).write(to: junk)

        await assertThrowsAsync { try await core.restoreBackup(from: junk) }

        // Still open, still intact, and no safety copy was made.
        let count = try await core.transactions(TxnQuery()).count
        XCTAssertEqual(count, 3)
        XCTAssertFalse(BackupManager.hasUndo(livePath: path("live.db")))
    }

    // MARK: Undo

    func testUndoPutsBackTheReplacedStore() async throws {
        let source = try core(at: "source.db")
        try seed(source.store, txnCount: 5)
        let backup = try await source.exportBackup()

        let target = try core(at: "target.db")
        try seed(target.store, txnCount: 2)       // the data the user is about to replace
        let liveBefore = try dump(path("target.db"))

        try await target.restoreBackup(from: backup)
        let afterRestore = try await target.transactions(TxnQuery()).count
        XCTAssertEqual(afterRestore, 5)
        let canUndo = await target.canUndoRestore()
        XCTAssertTrue(canUndo)

        try await target.undoRestore()
        let afterUndo = try await target.transactions(TxnQuery()).count
        XCTAssertEqual(afterUndo, 2)
        XCTAssertEqual(try dump(path("target.db")), liveBefore)

        // One generation only — the undo is consumed.
        let canUndoAgain = await target.canUndoRestore()
        XCTAssertFalse(canUndoAgain)
        await assertThrowsAsync { try await target.undoRestore() }
    }

    func testRestoreRollsBackWhenReopenFails() async throws {
        let source = try core(at: "source.db")
        try seed(source.store, txnCount: 5)
        let backup = try await source.exportBackup()

        // A live store the test owns outright, so it controls the connection.
        let livePath = path("live.db")
        let live = try Database(path: livePath)
        try seed(Store(live), txnCount: 2)
        try live.close()

        struct Boom: Error {}
        XCTAssertThrowsError(
            try BackupManager.restore(from: backup, into: livePath,
                                      closeLive: {}, reopen: { throw Boom() })
        ) { error in
            guard case .restoreFailed = error as? BackupError else {
                return XCTFail("expected restoreFailed, got \(error)")
            }
        }

        // The original store is back in place, untouched.
        XCTAssertEqual(try dump(livePath)["transactions"]?.count, 2)
        // Rolling back consumed the safety copy — no stale undo left behind.
        XCTAssertFalse(BackupManager.hasUndo(livePath: livePath))
    }

    // MARK: Helpers

    private func assertNotABackup(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BackupManager.inspect(at: url), file: file, line: line) { error in
            guard case .notABackup = error as? BackupError else {
                return XCTFail("expected notABackup for \(url.lastPathComponent), got \(error)", file: file, line: line)
            }
        }
    }

    private func scalar(_ sql: String, at dbPath: String) throws -> String? {
        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        return try queue.read { try String.fetchOne($0, sql: sql) }
    }

    /// Sync so GRDB's non-async `write` overload is the one selected.
    private func execute(_ sql: String, at dbPath: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        try queue.write { try $0.execute(sql: sql) }
    }

    private func appliedMigrations(_ dbPath: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        return try queue.read { try Database.migrator.appliedIdentifiers($0) }
    }

    private func assertThrowsAsync(file: StaticString = #filePath, line: UInt = #line,
                                   _ expression: () async throws -> Void) async {
        do {
            try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}
