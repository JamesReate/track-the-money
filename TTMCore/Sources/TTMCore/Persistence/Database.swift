import Foundation
import GRDB

/// Opens the on-device SQLite store (WAL, foreign keys, busy timeout) and owns
/// the schema migrations. TTMCore owns the DB connection; the app reaches data
/// only through the CoreFacade — never by touching GRDB directly. That choke
/// point is what keeps the future Rust port (TECH_DESIGN §13) bounded.
// GRDB's DatabaseQueue is thread-safe (serializes all access), so this wrapper
// is safe to share across concurrency domains.
public final class Database: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> Database {
        let db = try Database(path: ":memory:")
        return db
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_schema") { db in
            // Faithful subset of TECH_DESIGN §5. Kept as plain SQL (not a Swift
            // DSL) so it ports verbatim to rusqlite/sqlx in the Rust milestone.
            try db.execute(sql: """
            CREATE TABLE connections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              keychain_ref TEXT NOT NULL,
              sfin_org TEXT,
              status TEXT NOT NULL DEFAULT 'ok',
              last_error TEXT,
              last_synced_at INTEGER,
              created_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE accounts (
              id TEXT PRIMARY KEY,
              connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
              sfin_account_id TEXT NOT NULL,
              name TEXT NOT NULL,
              currency TEXT NOT NULL DEFAULT 'USD',
              class TEXT NOT NULL DEFAULT 'unclassified',
              subclass TEXT,
              apr_bps INTEGER,
              balance_cents INTEGER NOT NULL DEFAULT 0,
              available_cents INTEGER,
              balance_date INTEGER,
              archived INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              UNIQUE (connection_id, sfin_account_id)
            ) STRICT;

            CREATE TABLE balance_snapshots (
              id INTEGER PRIMARY KEY,
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              balance_cents INTEGER NOT NULL,
              available_cents INTEGER,
              balance_date INTEGER NOT NULL,
              recorded_at INTEGER NOT NULL,
              UNIQUE (account_id, balance_date)
            ) STRICT;

            CREATE TABLE categories (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              parent_id TEXT REFERENCES categories(id) ON DELETE CASCADE,
              kind TEXT NOT NULL DEFAULT 'expense',
              color TEXT,
              sort INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              UNIQUE (parent_id, name)
            ) STRICT;

            CREATE TABLE transactions (
              id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              sfin_txn_id TEXT NOT NULL,
              posted_at INTEGER,
              transacted_at INTEGER,
              amount_cents INTEGER NOT NULL,
              description TEXT NOT NULL DEFAULT '',
              payee TEXT,
              memo TEXT,
              pending INTEGER NOT NULL DEFAULT 0,
              category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
              category_source TEXT,
              is_transfer INTEGER NOT NULL DEFAULT 0,
              transfer_group_id TEXT,
              extra_json TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              UNIQUE (account_id, sfin_txn_id)
            ) STRICT;
            CREATE INDEX idx_txn_acct_posted ON transactions(account_id, posted_at);

            CREATE TABLE rules (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
              priority INTEGER NOT NULL DEFAULT 100,
              enabled INTEGER NOT NULL DEFAULT 1,
              conditions TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE properties (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT 'real_estate',
              created_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE property_values (
              id INTEGER PRIMARY KEY,
              property_id TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
              value_cents INTEGER NOT NULL,
              as_of INTEGER NOT NULL,
              note TEXT,
              created_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE property_debts (
              property_id TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              role TEXT NOT NULL DEFAULT 'mortgage',
              PRIMARY KEY (property_id, account_id)
            ) STRICT;

            CREATE TABLE payment_splits (
              id INTEGER PRIMARY KEY,
              transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
              principal_cents INTEGER NOT NULL DEFAULT 0,
              interest_cents INTEGER NOT NULL DEFAULT 0,
              escrow_cents INTEGER NOT NULL DEFAULT 0,
              source TEXT NOT NULL DEFAULT 'manual',
              created_at INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            ) STRICT;
            """)
        }

        migrator.registerMigration("v2_fts") { db in
            try db.execute(sql: """
            CREATE VIRTUAL TABLE transactions_fts USING fts5(
              description, payee, memo,
              content='transactions', content_rowid='rowid'
            );

            CREATE TRIGGER txn_fts_ai AFTER INSERT ON transactions BEGIN
              INSERT INTO transactions_fts(rowid, description, payee, memo)
              VALUES (new.rowid, new.description, COALESCE(new.payee,''), COALESCE(new.memo,''));
            END;
            CREATE TRIGGER txn_fts_ad AFTER DELETE ON transactions BEGIN
              INSERT INTO transactions_fts(transactions_fts, rowid, description, payee, memo)
              VALUES ('delete', old.rowid, old.description, COALESCE(old.payee,''), COALESCE(old.memo,''));
            END;
            CREATE TRIGGER txn_fts_au AFTER UPDATE ON transactions BEGIN
              INSERT INTO transactions_fts(transactions_fts, rowid, description, payee, memo)
              VALUES ('delete', old.rowid, old.description, COALESCE(old.payee,''), COALESCE(old.memo,''));
              INSERT INTO transactions_fts(rowid, description, payee, memo)
              VALUES (new.rowid, new.description, COALESCE(new.payee,''), COALESCE(new.memo,''));
            END;
            """)
        }

        migrator.registerMigration("v3_account_nickname") { db in
            // User-chosen display name. Never overwritten by sync (which only
            // updates `name` from SimpleFIN). The account's id / sfin_account_id
            // are untouched, so syncing continues unchanged.
            try db.execute(sql: "ALTER TABLE accounts ADD COLUMN nickname TEXT")
        }

        // ai_suggestions lands in a later migration with the AI (paid) feature.
        return migrator
    }
}
