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

    public func setAccountClass(id: String, accountClass: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET class = ? WHERE id = ?", arguments: [accountClass, id])
        }
    }

    public func setAccountNickname(id: String, nickname: String?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    public func findAccount(id: String) throws -> AccountRecord? {
        try queue.read { try AccountRecord.fetchOne($0, key: id) }
    }

    public func setAccountName(id: String, name: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET name = ?, nickname = NULL WHERE id = ?", arguments: [name, id])
        }
    }

    /// Set or (with nils) clear a card's promotional rate.
    public func setAccountPromo(id: String, aprBps: Int?, endsOn: Int64?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET promo_apr_bps = ?, promo_ends_on = ? WHERE id = ?",
                           arguments: [aprBps, endsOn, id])
        }
    }

    public func setAccountAPR(id: String, aprBps: Int?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET apr_bps = ? WHERE id = ?", arguments: [aprBps, id])
        }
    }

    /// Set whether an account counts / syncs. `resyncFrom` (when given) widens
    /// the next sync's window back to that time for this account's connection.
    public func setAccountStatus(id: String, status: AccountStatus, resyncFrom: Int64?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET status = ?, resync_from = COALESCE(?, resync_from) WHERE id = ?",
                           arguments: [status.rawValue, resyncFrom, id])
        }
    }

    /// Un-delete a tombstone and have the next sync reach back to `resyncFrom`.
    public func restoreAccount(id: String, resyncFrom: Int64) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE accounts SET archived = 0, resync_from = ? WHERE id = ?",
                           arguments: [resyncFrom, id])
        }
    }

    /// The earliest pending `resync_from` among a connection's live accounts.
    public func earliestResync(connectionId: String) throws -> Int64? {
        try queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT MIN(resync_from) FROM accounts
                WHERE connection_id = ? AND archived = 0 AND status <> 'paused'
                """, arguments: [connectionId])
        }
    }

    /// After a successful sync of a connection its catch-up windows are spent.
    /// A paused account keeps its own until it resumes.
    public func clearResync(connectionId: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE accounts SET resync_from = NULL
                WHERE connection_id = ? AND archived = 0 AND status <> 'paused'
                """, arguments: [connectionId])
        }
    }

    // MARK: Settings (per store, so per profile)

    public func setting(_ key: String) throws -> String? {
        try queue.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        try queue.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT (key) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Settings key: accounts that appear on an already-synced connection start
    /// out excluded until the user includes them. "1" = on; absent = off.
    public static let holdNewAccountsKey = "hold_new_accounts"

    /// Delete an account row; transactions, snapshots, splits and property-debt
    /// links cascade. Surviving transfer legs are un-paired first.
    public func deleteAccount(id: String) throws {
        try queue.write { db in
            try Self.unpairTransfers(db, accountId: id)
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
        }
    }

    /// Strip a synced account to a hidden tombstone: its data goes, the row
    /// stays (archived) so sync recognizes and skips it rather than re-importing.
    public func tombstoneAccount(id: String) throws {
        try queue.write { db in
            try Self.unpairTransfers(db, accountId: id)
            try db.execute(sql: "DELETE FROM transactions WHERE account_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM balance_snapshots WHERE account_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM property_debts WHERE account_id = ?", arguments: [id])
            try db.execute(sql: """
                UPDATE accounts SET archived = 1, balance_cents = 0, available_cents = NULL, balance_date = NULL
                WHERE id = ?
                """, arguments: [id])
        }
    }

    /// The other leg of any transfer pair touching `accountId` loses its pair:
    /// clear the flag and group, and the Transfer category if pairing set it.
    private static func unpairTransfers(_ db: GRDB.Database, accountId: String) throws {
        try db.execute(sql: """
            UPDATE transactions SET is_transfer = 0, transfer_group_id = NULL,
              category_id = CASE WHEN category_source = 'transfer' THEN NULL ELSE category_id END,
              category_source = CASE WHEN category_source = 'transfer' THEN NULL ELSE category_source END
            WHERE account_id <> ? AND transfer_group_id IN (
              SELECT transfer_group_id FROM transactions
              WHERE account_id = ? AND transfer_group_id IS NOT NULL)
            """, arguments: [accountId, accountId])
    }

    public func deleteConnection(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM connections WHERE id = ?", arguments: [id])
        }
    }

    public func snapshots(accountId: String) throws -> [BalanceSnapshotRecord] {
        try queue.read { db in
            try BalanceSnapshotRecord
                .filter(Column("account_id") == accountId)
                .order(Column("balance_date").desc)
                .fetchAll(db)
        }
    }

    /// Insert or replace the snapshot for (account, day), then set the account's
    /// current balance from its latest snapshot.
    public func upsertSnapshot(accountId: String, balanceCents: Int64, balanceDate: Int64, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO balance_snapshots (account_id, balance_cents, available_cents, balance_date, recorded_at)
                VALUES (?, ?, NULL, ?, ?)
                ON CONFLICT (account_id, balance_date)
                DO UPDATE SET balance_cents = excluded.balance_cents, recorded_at = excluded.recorded_at
                """, arguments: [accountId, balanceCents, balanceDate, now])
            try Self.balanceFromLatestSnapshot(db, accountId: accountId)
        }
    }

    /// Returns false (and deletes nothing) when it is the account's only snapshot.
    public func deleteSnapshot(accountId: String, balanceDate: Int64) throws -> Bool {
        try queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM balance_snapshots WHERE account_id = ?",
                                         arguments: [accountId]) ?? 0
            guard count > 1 else { return false }
            try db.execute(sql: "DELETE FROM balance_snapshots WHERE account_id = ? AND balance_date = ?",
                           arguments: [accountId, balanceDate])
            try Self.balanceFromLatestSnapshot(db, accountId: accountId)
            return true
        }
    }

    private static func balanceFromLatestSnapshot(_ db: GRDB.Database, accountId: String) throws {
        try db.execute(sql: """
            UPDATE accounts SET
              balance_cents = COALESCE((SELECT balance_cents FROM balance_snapshots
                                        WHERE account_id = ?1 ORDER BY balance_date DESC LIMIT 1), 0),
              balance_date = (SELECT MAX(balance_date) FROM balance_snapshots WHERE account_id = ?1)
            WHERE id = ?1
            """, arguments: [accountId])
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

    /// One transaction's match fields (joins account currency) — for on-demand
    /// on-device suggestion of a single uncategorized row.
    public func matchRow(transactionId: String) throws -> MatchRow? {
        try queue.read { db in
            try MatchRow.fetchOne(db, sql: """
                SELECT t.id, t.description, t.payee, t.memo, t.account_id,
                       t.amount_cents, a.currency, t.category_source
                FROM transactions t
                JOIN accounts a ON a.id = t.account_id
                WHERE t.id = ?
                """, arguments: [transactionId])
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

    // MARK: Transaction listing / search

    /// SQL predicate on a transactions alias `t`: the row belongs to an account
    /// that counts. An excluded account's transactions are stored (and still
    /// categorized by rules, so including it again is seamless) but read by
    /// nothing the user sees — ADR-0025.
    static let visibleTxn = "t.account_id NOT IN (SELECT id FROM accounts WHERE status = 'excluded')"

    /// Transactions of counting accounts only (see `visibleTxn`).
    public func transactions(_ q: TxnQuery) throws -> [TransactionRecord] {
        var sql = "SELECT t.* FROM transactions t"
        var conditions: [String] = [Self.visibleTxn]
        var args: [DatabaseValueConvertible] = []

        if let text = q.searchText, !text.isEmpty {
            sql += " JOIN transactions_fts f ON f.rowid = t.rowid"
            conditions.append("transactions_fts MATCH ?")
            args.append(ftsQuery(text))
        }
        if let accountId = q.accountId { conditions.append("t.account_id = ?"); args.append(accountId) }
        if let categoryId = q.categoryId { conditions.append("t.category_id = ?"); args.append(categoryId) }
        switch q.categorization {
        case .all: break
        case .categorized: conditions.append("t.category_id IS NOT NULL")
        case .uncategorized: conditions.append("t.category_id IS NULL")   // backed by idx_txn_uncat
        }
        if let from = q.from { conditions.append("t.posted_at >= ?"); args.append(from) }
        if let to = q.to { conditions.append("t.posted_at <= ?"); args.append(to) }
        if !q.includePending { conditions.append("t.pending = 0") }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY t.posted_at DESC LIMIT ?"
        args.append(q.limit)

        return try queue.read { try TransactionRecord.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }
    }

    /// Turn free text into a safe FTS5 prefix query (each token + '*').
    private func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\($0)*" }
            .joined(separator: " ")
    }

    // MARK: Transfers

    public struct TransferCandidate: FetchableRecord, Decodable {
        public var id: String
        public var accountId: String
        public var amountCents: Int64
        public var postedAt: Int64?
        enum CodingKeys: String, CodingKey {
            case id
            case accountId = "account_id"
            case amountCents = "amount_cents"
            case postedAt = "posted_at"
        }
    }

    /// Unpaired, uncategorized transactions of counting accounts: an excluded
    /// account can't turn a real payment into a transfer.
    public func transferCandidates() throws -> [TransferCandidate] {
        try queue.read { db in
            try TransferCandidate.fetchAll(db, sql: """
                SELECT t.id, t.account_id, t.amount_cents, t.posted_at
                FROM transactions t
                WHERE t.is_transfer = 0 AND t.category_id IS NULL AND t.amount_cents <> 0
                  AND \(Self.visibleTxn)
                """)
        }
    }

    public func markTransferPair(_ a: String, _ b: String, groupId: String, categoryId: String, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE transactions SET is_transfer = 1, transfer_group_id = ?, category_id = ?,
                  category_source = 'transfer', updated_at = ? WHERE id IN (?, ?)
                """, arguments: [groupId, categoryId, now, a, b])
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

    public func allCategories() throws -> [CategoryRecord] {
        try queue.read { try CategoryRecord.order(Column("sort")).fetchAll($0) }
    }

    public func findCategory(id: String) throws -> CategoryRecord? {
        try queue.read { try CategoryRecord.fetchOne($0, key: id) }
    }

    /// Transaction count per assigned category id (uncategorized rows and
    /// excluded accounts left out).
    public func transactionCountsByCategory() throws -> [String: Int] {
        struct Row: FetchableRecord, Decodable { var id: String; var n: Int }
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.category_id AS id, COUNT(*) AS n FROM transactions t
                WHERE t.category_id IS NOT NULL AND \(Self.visibleTxn)
                GROUP BY t.category_id
                """)
        }.reduce(into: [:]) { $0[$1.id] = $1.n }
    }

    public func uncategorizedCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transactions t WHERE t.category_id IS NULL AND \(Self.visibleTxn)
                """) ?? 0
        }
    }

    /// Repoint every transaction on `from` to `to` (used by delete/merge so the
    /// ON DELETE SET NULL on transactions never strands a categorized row).
    public func reassignTransactions(from: String, to: String, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE transactions SET category_id = ?, updated_at = ? WHERE category_id = ?",
                           arguments: [to, now, from])
        }
    }

    /// Repoint every rule on `from` to `to` (so a delete/merge doesn't cascade
    /// rules away via the rules.category_id ON DELETE CASCADE).
    public func repointRules(from: String, to: String, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE rules SET category_id = ?, updated_at = ? WHERE category_id = ?",
                           arguments: [to, now, from])
        }
    }

    /// Reparent children of `from` to `to` (nil = top level). Used when deleting a group.
    public func reparentChildren(from: String, to: String?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE categories SET parent_id = ? WHERE parent_id = ?", arguments: [to, from])
        }
    }

    public func setCategoryParent(id: String, parentId: String?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE categories SET parent_id = ? WHERE id = ?", arguments: [parentId, id])
        }
    }

    public func setCategorySort(id: String, sort: Int) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE categories SET sort = ? WHERE id = ?", arguments: [sort, id])
        }
    }

    public func deleteCategory(id: String) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM categories WHERE id = ?", arguments: [id]) }
    }

    public func deleteRule(id: String) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [id]) }
    }

    public struct SpendingRow: FetchableRecord, Decodable {
        public var id: String
        public var name: String
        public var cents: Int64
    }

    /// Spend (money out) by category in [from, to]; excludes transfers and
    /// excluded accounts.
    public func spendingByCategory(from: Int64, to: Int64) throws -> [SpendingRow] {
        try queue.read { db in
            try SpendingRow.fetchAll(db, sql: """
                SELECT COALESCE(c.id, 'uncategorized') AS id,
                       COALESCE(c.name, 'Uncategorized') AS name,
                       SUM(ABS(t.amount_cents)) AS cents
                FROM transactions t
                JOIN accounts a ON a.id = t.account_id
                LEFT JOIN categories c ON c.id = t.category_id
                WHERE t.amount_cents < 0 AND t.is_transfer = 0 AND a.status <> 'excluded'
                  AND t.posted_at >= ? AND t.posted_at <= ?
                GROUP BY 1, 2
                ORDER BY cents DESC
                """, arguments: [from, to])
        }
    }

    public func categoryCount() throws -> Int {
        try queue.read { try CategoryRecord.fetchCount($0) }
    }

    // MARK: Expected expenses (ADR-0027)

    public static let expectedMinimumKey = "expected_min_cents"
    public static let expectedLookbackKey = "expected_lookback_months"

    private struct ChargeRow: FetchableRecord, Decodable {
        var id: String
        var label: String
        var cents: Int64
        var at: Int64
        var account: String
        var categoryId: String?
    }

    /// Money out in [from, to) on counting accounts, as positive amounts:
    /// no transfers, nothing categorized as income or transfer. Pending
    /// charges are dated by when they happened.
    public func recurringCharges(from: Int64, to: Int64) throws -> [RecurringCharge] {
        try queue.read { db in
            try ChargeRow.fetchAll(db, sql: """
                SELECT t.id AS id,
                       COALESCE(NULLIF(t.payee, ''), t.description) AS label,
                       -t.amount_cents AS cents,
                       COALESCE(t.posted_at, t.transacted_at) AS at,
                       COALESCE(a.nickname, a.name) AS account,
                       t.category_id AS categoryId
                FROM transactions t
                JOIN accounts a ON a.id = t.account_id
                LEFT JOIN categories c ON c.id = t.category_id
                WHERE \(Self.visibleTxn) AND a.archived = 0
                  AND t.amount_cents < 0 AND t.is_transfer = 0
                  AND (c.kind IS NULL OR c.kind NOT IN ('income', 'transfer'))
                  AND COALESCE(t.posted_at, t.transacted_at) >= ?
                  AND COALESCE(t.posted_at, t.transacted_at) < ?
                """, arguments: [from, to])
        }.map {
            RecurringCharge(transactionId: $0.id, label: $0.label, amount: Money(cents: $0.cents), at: $0.at,
                            accountName: $0.account, categoryId: $0.categoryId)
        }
    }

    public func expectedDismissals() throws -> [DismissedExpense] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT merchant_key, name, dismissed_at FROM expected_expense_dismissals")
                .map { DismissedExpense(key: $0["merchant_key"], name: $0["name"], dismissedAt: $0["dismissed_at"]) }
        }
    }

    public func dismissExpected(key: String, name: String, now: Int64) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO expected_expense_dismissals (merchant_key, name, dismissed_at) VALUES (?, ?, ?)
                ON CONFLICT(merchant_key) DO UPDATE SET name = excluded.name, dismissed_at = excluded.dismissed_at
                """, arguments: [key, name, now])
        }
    }

    public func restoreExpected(key: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM expected_expense_dismissals WHERE merchant_key = ?", arguments: [key]) }
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
                WHERE a.status <> 'excluded'
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

    /// All snapshots joined to their account's class (skips deleted and
    /// excluded accounts).
    public func seriesSnapshots() throws -> [SeriesSnapshot] {
        try queue.read { db in
            try SnapRow.fetchAll(db, sql: """
                SELECT s.account_id, a.class, s.balance_cents, s.balance_date
                FROM balance_snapshots s
                JOIN accounts a ON a.id = s.account_id
                WHERE a.archived = 0 AND a.status <> 'excluded'
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

    /// Debt-account snapshots (secured + unsecured only), for the debt-over-time
    /// series. `class` stores AccountClass raw values (camelCase).
    public func debtSeriesSnapshots() throws -> [DebtSeriesSnapshot] {
        try queue.read { db in
            try SnapRow.fetchAll(db, sql: """
                SELECT s.account_id, a.class, s.balance_cents, s.balance_date
                FROM balance_snapshots s
                JOIN accounts a ON a.id = s.account_id
                WHERE a.archived = 0 AND a.status <> 'excluded'
                  AND a.class IN ('securedDebt', 'creditCard', 'unsecuredDebt')
                """)
        }.map { row in
            DebtSeriesSnapshot(accountId: row.accountId, secured: row.accountClass == AccountClass.securedDebt.rawValue,
                               balanceCents: row.balanceCents, balanceDate: row.balanceDate)
        }
    }

    public func seriesPropertyValues() throws -> [SeriesPropertyValue] {
        try queue.read { db in
            try PropValRow.fetchAll(db, sql: "SELECT property_id, value_cents, as_of FROM property_values")
        }.map { SeriesPropertyValue(propertyId: $0.propertyId, valueCents: $0.valueCents, asOf: $0.asOf) }
    }

    // MARK: Properties

    public func saveProperty(_ p: PropertyRecord) throws { try queue.write { try p.save($0) } }
    public func addPropertyValue(_ v: PropertyValueRecord) throws { var v = v; try queue.write { try v.insert($0) } }
    public func linkDebt(_ d: PropertyDebtRecord) throws { try queue.write { try d.save($0) } }
    public func unlinkDebt(propertyId: String, accountId: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM property_debts WHERE property_id = ? AND account_id = ?",
                           arguments: [propertyId, accountId])
        }
    }

    public struct PropertySummaryRow: FetchableRecord, Decodable {
        public var id: String
        public var name: String
        public var valueCents: Int64
        public var debtCents: Int64
        enum CodingKeys: String, CodingKey {
            case id, name
            case valueCents = "value_cents"
            case debtCents = "debt_cents"
        }
    }

    /// Each property with its latest value and the summed balance of linked debt
    /// accounts (magnitudes).
    public func propertySummaries() throws -> [PropertySummaryRow] {
        try queue.read { db in
            try PropertySummaryRow.fetchAll(db, sql: """
                SELECT p.id, p.name,
                  COALESCE((SELECT pv.value_cents FROM property_values pv
                            WHERE pv.property_id = p.id ORDER BY pv.as_of DESC LIMIT 1), 0) AS value_cents,
                  COALESCE((SELECT SUM(ABS(a.balance_cents)) FROM property_debts pd
                            JOIN accounts a ON a.id = pd.account_id
                            WHERE pd.property_id = p.id AND a.status <> 'excluded'), 0) AS debt_cents
                FROM properties p
                ORDER BY p.name
                """)
        }
    }

    /// Total magnitude of the counting debt accounts linked to any property (an
    /// excluded mortgage leaves liabilities, so it leaves equity too).
    public func linkedDebtTotalCents() throws -> Int64 {
        try queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(ABS(a.balance_cents)), 0)
                FROM property_debts pd JOIN accounts a ON a.id = pd.account_id
                WHERE a.status <> 'excluded'
                """) ?? 0
        }
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
