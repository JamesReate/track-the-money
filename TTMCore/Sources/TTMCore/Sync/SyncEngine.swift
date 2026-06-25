import Foundation

// On-device SimpleFIN sync (TECH_DESIGN §6). Runs in BOTH tiers; the server
// never calls SimpleFIN. Idempotent upsert on (account_id, sfin_txn_id); balance
// snapshots on (account_id, balance_date); pending→posted reconciliation;
// per-connection failure isolation. Weekly cadence + manual "Sync now" are
// driven by the app layer calling run().

public struct SyncEngine: Sendable {
    private let store: Store
    private let client: SimpleFINClient
    private let secrets: SecretStore
    private let clock: Clock
    private let categorizer: Categorizer

    public init(store: Store, client: SimpleFINClient, secrets: SecretStore, clock: Clock) {
        self.store = store
        self.client = client
        self.secrets = secrets
        self.clock = clock
        self.categorizer = Categorizer(store: store, clock: clock)
    }

    /// Re-pull recent transactions with overlap so late posts/edits are caught.
    public static let overlap: UnixTime = 7 * Time.secondsPerDay
    /// How far back to reach on a connection's first sync.
    public static let defaultBackfill: UnixTime = 120 * Time.secondsPerDay

    public func run() async -> SyncOutcome {
        var succeeded = 0, failed = 0, newTxns = 0
        let now = clock.now()
        let rules = (try? categorizer.loadRules()) ?? []
        let connections = (try? store.allConnections()) ?? []

        for conn in connections {
            do {
                newTxns += try await syncConnection(conn, rules: rules, now: now)
                try store.updateConnectionStatus(id: conn.id, status: "ok", lastError: nil, lastSyncedAt: now)
                succeeded += 1
            } catch {
                // One failing connection never blocks the others.
                let status = (error as? TTMError) == .network("HTTP 403") ? "needs_auth" : "error"
                try? store.updateConnectionStatus(id: conn.id, status: status, lastError: "\(error)", lastSyncedAt: nil)
                failed += 1
            }
        }
        return SyncOutcome(connectionsSucceeded: succeeded, connectionsFailed: failed, newTransactions: newTxns)
    }

    private func syncConnection(_ conn: ConnectionRecord, rules: [Rule], now: UnixTime) async throws -> Int {
        guard let accessString = try secrets.read(ref: conn.keychainRef),
              let accessURL = URL(string: accessString) else {
            throw TTMError.simplefin("missing access URL")
        }

        let start = (conn.lastSyncedAt.map { $0 - Self.overlap }) ?? (now - Self.defaultBackfill)
        let set = try await client.fetchAccounts(accessURL: accessURL, start: start, end: now, pending: true)

        var newCount = 0
        for sf in set.accounts {
            let account = try upsertAccount(conn: conn, sf: sf, now: now)
            try snapshot(account: account, sf: sf, now: now)
            for tx in sf.transactions ?? [] {
                if try upsertTransaction(account: account, tx: tx, rules: rules, now: now) { newCount += 1 }
            }
        }
        return newCount
    }

    private func upsertAccount(conn: ConnectionRecord, sf: SFAccount, now: UnixTime) throws -> AccountRecord {
        let balance = sf.balanceCents?.cents ?? 0
        let available = sf.availableCents?.cents

        if var existing = try store.findAccount(connectionId: conn.id, sfinAccountId: sf.id) {
            existing.name = sf.name
            existing.currency = sf.currency
            existing.balanceCents = balance
            existing.availableCents = available
            existing.balanceDate = sf.balanceDate
            try store.saveAccount(existing)        // class/subclass/apr untouched
            return existing
        }

        // First sight: smart-default class (never overrides a user later).
        let record = AccountRecord(
            id: UUID().uuidString,
            connectionId: conn.id,
            sfinAccountId: sf.id,
            name: sf.name,
            currency: sf.currency,
            accountClass: AccountClassifier.guess(name: sf.name).rawValue,
            subclass: nil,
            aprBps: nil,
            balanceCents: balance,
            availableCents: available,
            balanceDate: sf.balanceDate,
            archived: false,
            createdAt: now
        )
        try store.saveAccount(record)
        return record
    }

    private func snapshot(account: AccountRecord, sf: SFAccount, now: UnixTime) throws {
        guard let balanceDate = sf.balanceDate else { return }
        try store.insertSnapshotIfAbsent(BalanceSnapshotRecord(
            id: nil,
            accountId: account.id,
            balanceCents: account.balanceCents,
            availableCents: account.availableCents,
            balanceDate: balanceDate,
            recordedAt: now
        ))
    }

    /// Returns true if a brand-new transaction was inserted.
    private func upsertTransaction(account: AccountRecord, tx: SFTransaction, rules: [Rule], now: UnixTime) throws -> Bool {
        let amount = tx.amountCents?.cents ?? 0
        let description = tx.description ?? ""

        if var existing = try store.findTransaction(accountId: account.id, sfinTxnId: tx.id) {
            // Update mutable fields; handle pending→posted. Never clobber manual.
            existing.amountCents = amount
            existing.description = description
            existing.payee = tx.payee
            existing.memo = tx.memo
            existing.pending = tx.isPending
            existing.postedAt = tx.posted
            existing.transactedAt = tx.transactedAt
            existing.updatedAt = now
            try store.saveTransaction(existing)
            return false
        }

        var record = TransactionRecord(
            id: UUID().uuidString,
            accountId: account.id,
            sfinTxnId: tx.id,
            postedAt: tx.posted,
            transactedAt: tx.transactedAt,
            amountCents: amount,
            description: description,
            payee: tx.payee,
            memo: tx.memo,
            pending: tx.isPending,
            categoryId: nil,
            categorySource: nil,
            isTransfer: false,
            transferGroupId: nil,
            extraJson: nil,
            createdAt: now,
            updatedAt: now
        )

        // Deterministic rules at insert time (free tier stops here).
        let view = TxnView(description: description, payee: tx.payee, memo: tx.memo,
                           accountId: account.id, amountCents: amount, currency: account.currency)
        if let hit = categorizer.categorize(view, rules: rules) {
            record.categoryId = hit.categoryId
            record.categorySource = hit.source
        }
        try store.saveTransaction(record)
        return true
    }
}
