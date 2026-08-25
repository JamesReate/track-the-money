import Foundation
import GRDB

// Backup & restore of the whole store as a single SQLite file
// (docs/plans/DATA_PORTABILITY_PLAN.md). The format IS the database: `VACUUM
// INTO` yields a consistent, checkpointed, WAL-free copy carrying every table,
// the FTS shadow tables, and `grdb_migrations` — so nothing can be forgotten
// when the schema grows, and restoring an older backup just re-runs the normal
// migrations. Restore is replace-everything; merging two stores is explicitly
// out of scope.
//
// The secret (SimpleFIN access URL) lives in the Keychain, never the DB, so it
// is absent from backups by construction — and stays that way (§5 D8).

/// Validated summary of a candidate backup, shown before anything is replaced.
public struct BackupInfo: Equatable, Sendable {
    public let accounts: Int
    public let transactions: Int
    public let categories: Int
    public let rules: Int
    public let properties: Int
    /// Newest `posted_at` in the file — lets the UI say "data through <date>".
    public let newestTransactionAt: UnixTime?
    public let fileSizeBytes: Int64
    /// Schema migrations present in the file, in registration order.
    public let migrations: [String]

    public init(accounts: Int, transactions: Int, categories: Int, rules: Int, properties: Int,
                newestTransactionAt: UnixTime?, fileSizeBytes: Int64, migrations: [String]) {
        self.accounts = accounts; self.transactions = transactions
        self.categories = categories; self.rules = rules; self.properties = properties
        self.newestTransactionAt = newestTransactionAt
        self.fileSizeBytes = fileSizeBytes; self.migrations = migrations
    }

    /// True when the file predates the running app's schema — restoring it is
    /// fine (migrations run on reopen), this is only for messaging.
    public var needsMigration: Bool { migrations.count < Database.knownMigrations.count }
}

public enum BackupError: Error, Equatable, LocalizedError {
    /// The file is not a Track The Money backup (wrong magic, missing tables…).
    case notABackup(String)
    /// Valid SQLite, but corrupt.
    case damaged(String)
    /// Written by a newer app version; migrations cannot run backwards.
    case needsNewerApp([String])
    case exportFailed(String)
    case restoreFailed(String)
    case nothingToUndo

    public var errorDescription: String? {
        switch self {
        case .notABackup(let why):    return "This isn't a Track The Money backup (\(why))."
        case .damaged(let why):       return "This backup is damaged and can't be restored (\(why))."
        case .needsNewerApp:          return "This backup was made by a newer version of Track The Money. Update the app, then restore."
        case .exportFailed(let why):  return "Couldn't write the backup (\(why))."
        case .restoreFailed(let why): return "Couldn't restore the backup (\(why)). Your existing data was put back."
        case .nothingToUndo:          return "There's no restore to undo."
        }
    }
}

public enum BackupManager {
    public static let fileExtension = "ttmbackup"
    /// One generation of undo, kept beside the live store (§5 D5a).
    static let preRestoreSuffix = ".pre-restore"

    /// Every SQLite file starts with this 16-byte header.
    private static let sqliteMagic = Array("SQLite format 3\u{0}".utf8)
    private static let maxBackupBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Real tables every ttm store has. FTS virtual tables are deliberately not
    /// listed — they're an implementation detail that arrived in v2.
    static let requiredTables = [
        "connections", "accounts", "balance_snapshots", "categories", "transactions",
        "rules", "properties", "property_values", "property_debts", "payment_splits",
        "grdb_migrations",
    ]

    // MARK: Export

    /// Write a consistent snapshot of `database` to `url`, replacing any file
    /// there. Runs through the write queue, so it serializes behind in-flight
    /// work and needs no app-level coordination.
    @discardableResult
    public static func export(from database: Database, to url: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // VACUUM INTO refuses to overwrite.
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        do {
            try database.dbQueue.vacuum(into: url.path)
        } catch {
            throw BackupError.exportFailed(String(describing: error))
        }
        return url
    }

    /// `TrackTheMoney-2026-08-24.ttmbackup`
    public static func suggestedFilename(now: UnixTime) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let stamp = df.string(from: Date(timeIntervalSince1970: TimeInterval(now)))
        return "TrackTheMoney-\(stamp).\(fileExtension)"
    }

    // MARK: Inspect / validate

    /// Validate a candidate file and summarize it. Opens read-only and never
    /// touches the live store — every restore path runs this first.
    public static func inspect(at url: URL) throws -> BackupInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw BackupError.notABackup("file not found") }

        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw BackupError.notABackup("the file is empty") }
        guard size <= maxBackupBytes else { throw BackupError.notABackup("the file is implausibly large") }

        // Cheapest possible rejection of the obviously-wrong file.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw BackupError.notABackup("the file can't be read")
        }
        let head = (try? handle.read(upToCount: sqliteMagic.count)) ?? Data()
        try? handle.close()
        guard Array(head) == sqliteMagic else { throw BackupError.notABackup("not a SQLite database") }

        let (queue, scratch) = try openForReading(url)
        defer {
            try? queue.close()
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }

        do {
            return try queue.read { conn in
                let check = try String.fetchOne(conn, sql: "PRAGMA quick_check")
                guard check == "ok" else { throw BackupError.damaged(check ?? "integrity check failed") }

                for table in requiredTables where try !conn.tableExists(table) {
                    throw BackupError.notABackup("missing the '\(table)' table")
                }

                // Migrations can't run backwards: refuse a file from a newer app.
                let applied = try Database.migrator.appliedIdentifiers(conn)
                let unknown = applied.subtracting(Database.knownMigrations).sorted()
                guard unknown.isEmpty else { throw BackupError.needsNewerApp(unknown) }

                func count(_ table: String) throws -> Int {
                    try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                }
                return BackupInfo(
                    accounts: try count("accounts"),
                    transactions: try count("transactions"),
                    categories: try count("categories"),
                    rules: try count("rules"),
                    properties: try count("properties"),
                    newestTransactionAt: try Int64.fetchOne(conn, sql: "SELECT MAX(posted_at) FROM transactions"),
                    fileSizeBytes: size,
                    migrations: Database.knownMigrations.filter { applied.contains($0) }
                )
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.damaged(String(describing: error))
        }
    }

    /// Open a candidate for inspection without ever writing to the user's file.
    ///
    /// Read-only is the fast path and works for anything we produced (`VACUUM
    /// INTO` output carries no WAL). A file copied straight out of a live app
    /// container is still in WAL mode, though, and SQLite refuses a read-only
    /// open of one whose `-shm` sidecar is absent — so fall back to a private
    /// copy we're allowed to write to. Returns the scratch file to clean up.
    private static func openForReading(_ url: URL) throws -> (DatabaseQueue, URL?) {
        // Deliberately NOT our live Configuration: `prepareDatabase` sets
        // journal_mode = WAL, which fails against a read-only file.
        var config = Configuration()
        config.readonly = true
        if let queue = try? DatabaseQueue(path: url.path, configuration: config) {
            return (queue, nil)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-inspect-\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(at: url, to: scratch)
            return (try DatabaseQueue(path: scratch.path), scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw BackupError.damaged(String(describing: error))
        }
    }

    // MARK: Restore

    /// Replace the store at `livePath` with `url`. Validates first, keeps one
    /// generation of undo, and puts the old store back if anything fails —
    /// including a failure to reopen the restored file.
    ///
    /// `closeLive` must release the live connection; `reopen` rebuilds it.
    @discardableResult
    public static func restore(from url: URL, into livePath: String,
                               closeLive: () throws -> Void,
                               reopen: () throws -> Void) throws -> BackupInfo {
        let info = try inspect(at: url)          // never touch the store before this passes
        let fm = FileManager.default
        let live = URL(fileURLWithPath: livePath)
        let safety = URL(fileURLWithPath: livePath + preRestoreSuffix)

        try closeLive()

        try? fm.removeItem(at: safety)
        if fm.fileExists(atPath: live.path) {
            do { try fm.moveItem(at: live, to: safety) }
            catch {
                try? reopen()
                throw BackupError.restoreFailed("couldn't set aside the current data: \(error)")
            }
        }
        // A stale -wal/-shm from the old store must never meet the new file.
        removeSidecars(of: live)

        do {
            try fm.copyItem(at: url, to: live)
            try reopen()
            return info
        } catch {
            rollBack(live: live, safety: safety, reopen: reopen)
            throw BackupError.restoreFailed(String(describing: error))
        }
    }

    /// Is there a pre-restore store to go back to?
    public static func hasUndo(livePath: String) -> Bool {
        FileManager.default.fileExists(atPath: livePath + preRestoreSuffix)
    }

    /// Put back the store that the last restore replaced. Consumes the undo —
    /// one generation only, so there is no undo-the-undo.
    public static func undo(livePath: String,
                            closeLive: () throws -> Void,
                            reopen: () throws -> Void) throws {
        let fm = FileManager.default
        let live = URL(fileURLWithPath: livePath)
        let safety = URL(fileURLWithPath: livePath + preRestoreSuffix)
        guard fm.fileExists(atPath: safety.path) else { throw BackupError.nothingToUndo }

        try closeLive()
        try? fm.removeItem(at: live)
        removeSidecars(of: live)
        do {
            try fm.moveItem(at: safety, to: live)
            try reopen()
        } catch {
            try? reopen()
            throw BackupError.restoreFailed(String(describing: error))
        }
    }

    /// Drop the undo copy (e.g. once the user is happy, or to reclaim space).
    public static func discardUndo(livePath: String) {
        try? FileManager.default.removeItem(atPath: livePath + preRestoreSuffix)
    }

    // MARK: File helpers

    private static func removeSidecars(of live: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: live.path + suffix)
        }
    }

    private static func rollBack(live: URL, safety: URL, reopen: () throws -> Void) {
        let fm = FileManager.default
        try? fm.removeItem(at: live)
        removeSidecars(of: live)
        if fm.fileExists(atPath: safety.path) {
            try? fm.moveItem(at: safety, to: live)
        }
        try? reopen()   // best effort: never leave the app without a store
    }
}
