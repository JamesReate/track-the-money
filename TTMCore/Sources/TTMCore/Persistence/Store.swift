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

    public func ruleCount() throws -> Int {
        try queue.read { try RuleRecord.fetchCount($0) }
    }

    public func saveCategory(_ c: CategoryRecord) throws {
        try queue.write { try c.save($0) }
    }

    public func categoryCount() throws -> Int {
        try queue.read { try CategoryRecord.fetchCount($0) }
    }

    // MARK: Payment splits & interest

    /// One split per transaction: replace any existing.
    public func setPaymentSplit(transactionId: String, principal: Int64, interest: Int64, escrow: Int64, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM payment_splits WHERE transaction_id = ?", arguments: [transactionId])
            try db.execute(sql: """
                INSERT INTO payment_splits (transaction_id, principal_cents, interest_cents, escrow_cents, source, created_at)
                VALUES (?, ?, ?, ?, 'manual', ?)
                """, arguments: [transactionId, principal, interest, escrow, now])
        }
    }

    private struct InterestRow: FetchableRecord, Decodable {
        var id: String
        var name: String
        var cents: Int64
    }

    /// Interest paid per account in [from, to], combining interest-categorized
    /// transactions and the interest portion of payment splits.
    public func interestByAccount(categoryId: String, from: Int64, to: Int64) throws -> [(accountId: String, name: String, cents: Int64)] {
        try queue.read { db in
            try InterestRow.fetchAll(db, sql: """
                SELECT a.id AS id, a.name AS name, SUM(x.cents) AS cents
                FROM (
                    SELECT account_id, ABS(amount_cents) AS cents
                    FROM transactions
                    WHERE category_id = ? AND posted_at >= ? AND posted_at <= ?
                    UNION ALL
                    SELECT t.account_id, ps.interest_cents AS cents
                    FROM payment_splits ps
                    JOIN transactions t ON t.id = ps.transaction_id
                    WHERE t.posted_at >= ? AND t.posted_at <= ?
                ) x
                JOIN accounts a ON a.id = x.account_id
                GROUP BY a.id, a.name
                HAVING cents <> 0
                ORDER BY cents DESC
                """, arguments: [categoryId, from, to, from, to])
        }.map { ($0.id, $0.name, $0.cents) }
    }

    // MARK: Net worth inputs

    private struct SnapRow: FetchableRecord, Decodable {
        var accountId: String
        var accountClass: String
        var balanceCents: Int64
        var balanceDate: Int64
        enum CodingKeys: String, CodingKey {
            case accountId = "account_id"
            case accountClass = "class"
            case balanceCents = "balance_cents"
            case balanceDate = "balance_date"
        }
    }

    /// All snapshots joined to their account's class (excludes archived/excluded).
    public func seriesSnapshots() throws -> [SeriesSnapshot] {
        try queue.read { db in
            try SnapRow.fetchAll(db, sql: """
                SELECT s.account_id, a.class, s.balance_cents, s.balance_date
                FROM balance_snapshots s
                JOIN accounts a ON a.id = s.account_id
                WHERE a.archived = 0 AND a.class <> 'excluded'
                """)
        }.map { row in
            let cls = AccountClass(rawValue: row.accountClass) ?? .unclassified
            return SeriesSnapshot(accountId: row.accountId, contribution: cls.contribution,
                                  balanceCents: row.balanceCents, balanceDate: row.balanceDate)
        }
    }

    private struct PropValRow: FetchableRecord, Decodable {
        var propertyId: String
        var valueCents: Int64
        var asOf: Int64
        enum CodingKeys: String, CodingKey {
            case propertyId = "property_id"
            case valueCents = "value_cents"
            case asOf = "as_of"
        }
    }

    public func seriesPropertyValues() throws -> [SeriesPropertyValue] {
        try queue.read { db in
            try PropValRow.fetchAll(db, sql: "SELECT property_id, value_cents, as_of FROM property_values")
        }.map { SeriesPropertyValue(propertyId: $0.propertyId, valueCents: $0.valueCents, asOf: $0.asOf) }
    }

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
