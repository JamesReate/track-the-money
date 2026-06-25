import Foundation
import GRDB

// Data-access layer over GRDB. The sync engine, categorizer, and facade go
// through this — they never touch GRDB directly. Keeps SQL in one place and the
// CoreFacade swap (Rust port) bounded.
public struct Store: Sendable {
    private let db: Database
    public init(_ db: Database) { self.db = db }

    private var queue: DatabaseQueue { db.dbQueue }

    // MARK: Connections

    public func allConnections() throws -> [ConnectionRecord] {
        try queue.read { try ConnectionRecord.fetchAll($0) }
    }

    public func saveConnection(_ c: ConnectionRecord) throws {
        try queue.write { try c.save($0) }
    }

    public func updateConnectionStatus(id: String, status: String, lastError: String?, lastSyncedAt: Int64?) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE connections SET status = ?, last_error = ?, last_synced_at = COALESCE(?, last_synced_at)
                WHERE id = ?
                """, arguments: [status, lastError, lastSyncedAt, id])
        }
    }

    // MARK: Accounts

    public func allAccounts() throws -> [AccountRecord] {
        try queue.read { try AccountRecord.fetchAll($0) }
    }

    public func findAccount(connectionId: String, sfinAccountId: String) throws -> AccountRecord? {
        try queue.read { db in
            try AccountRecord
                .filter(Column("connection_id") == connectionId && Column("sfin_account_id") == sfinAccountId)
                .fetchOne(db)
        }
    }

    public func saveAccount(_ a: AccountRecord) throws {
        try queue.write { try a.save($0) }
    }

    /// Insert a balance snapshot, ignoring the (account_id, balance_date) dupe.
    public func insertSnapshotIfAbsent(_ s: BalanceSnapshotRecord) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO balance_snapshots
                  (account_id, balance_cents, available_cents, balance_date, recorded_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [s.accountId, s.balanceCents, s.availableCents, s.balanceDate, s.recordedAt])
        }
    }

    // MARK: Transactions

    public func findTransaction(accountId: String, sfinTxnId: String) throws -> TransactionRecord? {
        try queue.read { db in
            try TransactionRecord
                .filter(Column("account_id") == accountId && Column("sfin_txn_id") == sfinTxnId)
                .fetchOne(db)
        }
    }

    public func saveTransaction(_ t: TransactionRecord) throws {
        try queue.write { try t.save($0) }
    }

    public func setTransactionCategory(id: String, categoryId: String?, source: String?, updatedAt: Int64) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE transactions SET category_id = ?, category_source = ?, updated_at = ? WHERE id = ?
                """, arguments: [categoryId, source, updatedAt, id])
        }
    }

    /// Rows used for rule matching (joins account currency).
    public struct MatchRow: FetchableRecord, Decodable {
        public var id: String
        public var description: String
        public var payee: String?
        public var memo: String?
        public var accountId: String
        public var amountCents: Int64
        public var currency: String
        public var categorySource: String?

        enum CodingKeys: String, CodingKey {
            case id, description, payee, memo, currency
            case accountId = "account_id"
            case amountCents = "amount_cents"
            case categorySource = "category_source"
        }
    }

    public func transactionsForMatching(onlyUncategorized: Bool) throws -> [MatchRow] {
        let predicate = onlyUncategorized ? "WHERE t.category_id IS NULL" : "WHERE t.category_source IS NOT 'manual'"
        return try queue.read { db in
            try MatchRow.fetchAll(db, sql: """
                SELECT t.id, t.description, t.payee, t.memo, t.account_id,
                       t.amount_cents, a.currency, t.category_source
                FROM transactions t
                JOIN accounts a ON a.id = t.account_id
                \(predicate)
                """)
        }
    }

    // MARK: Rules / categories

    public func allRuleRecords() throws -> [RuleRecord] {
        try queue.read { try RuleRecord.order(Column("priority")).fetchAll($0) }
    }

    public func saveRuleRecord(_ r: RuleRecord) throws {
        try queue.write { try r.save($0) }
    }

    public func saveCategory(_ c: CategoryRecord) throws {
        try queue.write { try c.save($0) }
    }

    public func categoryCount() throws -> Int {
        try queue.read { try CategoryRecord.fetchCount($0) }
    }

    // MARK: Net worth inputs

    /// Latest value per property (max as_of), as cents.
    public func latestPropertyValuesCents() throws -> [Int64] {
        try queue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT pv.value_cents
                FROM property_values pv
                WHERE pv.as_of = (
                    SELECT MAX(pv2.as_of) FROM property_values pv2 WHERE pv2.property_id = pv.property_id
                )
                """)
        }
    }
}
