import XCTest
import GRDB
@testable import TTMCore

/// Excluded and paused accounts, and holding newly shared ones (ADR-0025).
final class AccountStatusTests: XCTestCase {
    private static let day: UnixTime = 86_400
    private static let start: UnixTime = 1_700_000_000

    private final class Clock: TTMCore.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: UnixTime = AccountStatusTests.start
        func now() -> UnixTime { lock.lock(); defer { lock.unlock() }; return t }
        func advance(days: Int64) { lock.lock(); t += days * AccountStatusTests.day; lock.unlock() }
    }

    private final class Secrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        func read(ref: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return storage[ref] }
        func write(_ value: String, ref: String) throws { lock.lock(); storage[ref] = value; lock.unlock() }
        func delete(ref: String) throws { lock.lock(); storage[ref] = nil; lock.unlock() }
    }

    /// A bridge whose shared accounts the test changes between syncs. Each
    /// account reports a balance dated `now` and one transaction per sync, so
    /// a sync that touches an account visibly moves it. Records `start-date`.
    private final class Bridge: NetworkClient, @unchecked Sendable {
        struct Account { var id: String; var name: String; var balanceCents: Int64 }
        private let lock = NSLock()
        private let clock: Clock
        private var _accounts: [Account]
        private var _starts: [UnixTime] = []
        init(clock: Clock, accounts: [Account]) { self.clock = clock; self._accounts = accounts }

        var accounts: [Account] {
            get { lock.lock(); defer { lock.unlock() }; return _accounts }
            set { lock.lock(); _accounts = newValue; lock.unlock() }
        }
        var starts: [UnixTime] { lock.lock(); defer { lock.unlock() }; return _starts }

        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data {
            let start = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "start-date" }?.value.flatMap { UnixTime($0) }
            let now = clock.now()
            lock.lock(); if let start { _starts.append(start) }; let accounts = _accounts; lock.unlock()
            let body = accounts.map { a in
                """
                { "id": "\(a.id)", "name": "\(a.name)", "currency": "USD",
                  "balance": "\(Decimal(a.balanceCents) / 100)", "balance-date": \(now),
                  "transactions": [ { "id": "\(a.id)-\(now)", "posted": \(now - 60), "amount": "-10.00",
                                      "description": "COFFEE" } ] }
                """
            }.joined(separator: ",")
            return Data(#"{ "errors": [], "accounts": [\#(body)] }"#.utf8)
        }

        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data {
            Data("https://user:pass@bridge.test/simplefin".utf8)
        }
    }

    private var dir: URL!
    private var clock: Clock!
    private var bridge: Bridge!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = Clock()
        bridge = Bridge(clock: clock, accounts: [.init(id: "chk", name: "Everyday Checking", balanceCents: 100_000),
                                                 .init(id: "card", name: "Work Visa", balanceCents: -20_000)])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A core that has claimed a connection and synced it once.
    private func syncedCore() async throws -> LocalCore {
        let core = try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: Secrets(),
                                 network: bridge, clock: clock)
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        _ = try await core.syncNow()
        return core
    }

    private func account(_ name: String, _ core: LocalCore) async throws -> AccountSummary {
        let found = try await core.accounts().first { $0.syncedName == name }
        return try XCTUnwrap(found)
    }

    private func transactionCount(_ accountId: String, _ core: LocalCore) async throws -> Int {
        try await core.transactions(TxnQuery(accountId: accountId)).count
    }

    // MARK: Excluded

    func testExcludedAccountKeepsSyncingButLeavesEveryTotal() async throws {
        let core = try await syncedCore()
        let card = try await account("Work Visa", core)
        XCTAssertEqual(card.status, .active)
        XCTAssertEqual(card.accountClass, .creditCard)
        try await core.setAccountStatus(accountId: card.id, status: .excluded)

        bridge.accounts[1].balanceCents = -35_000
        clock.advance(days: 1)
        _ = try await core.syncNow()

        let after = try await account("Work Visa", core)
        XCTAssertEqual(after.status, .excluded)
        XCTAssertEqual(after.accountClass, .creditCard, "excluding keeps the account's kind")
        XCTAssertEqual(after.balance, Money(cents: -35_000), "an excluded account still syncs")

        // Its transactions are stored but nothing the user sees reads them.
        let hiddenTxns = try await transactionCount(card.id, core)
        XCTAssertEqual(hiddenTxns, 0, "not even when asked for by account")
        let listed = try await core.transactions(TxnQuery())
        XCTAssertTrue(listed.allSatisfy { $0.accountId != card.id })
        XCTAssertEqual(listed.count, 2, "checking's two coffees only")
        let searched = try await core.transactions(TxnQuery(searchText: "coffee"))
        XCTAssertEqual(searched.count, 2)
        let uncategorized = try await core.uncategorizedCount()
        XCTAssertEqual(uncategorized, 2)
        let review = try await core.transactions(TxnQuery(categorization: .uncategorized))
        XCTAssertEqual(review.count, 2)
        for synced in [Self.start, clock.now()] {
            XCTAssertNotNil(try core.store.findTransaction(accountId: card.id, sfinTxnId: "card-\(synced)"),
                            "still stored and still syncing")
        }

        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.liabilities, .zero)
        XCTAssertEqual(netWorth.assets, Money(cents: 100_000))
        let series = try await core.netWorthSeries(from: nil, to: nil)
        XCTAssertEqual(series.last?.netWorth, Money(cents: 100_000))
        let debt = try await core.debtSeries(from: nil, to: nil)
        XCTAssertTrue(debt.allSatisfy { $0.unsecured == .zero })
        let spending = try await core.spending(from: 0, to: clock.now())
        XCTAssertEqual(spending.reduce(Money.zero) { $0 + $1.amount }, Money(cents: 2_000),
                       "only checking's two coffees count")

        try await core.setAccountStatus(accountId: card.id, status: .active)
        let back = try await core.netWorthSummary()
        XCTAssertEqual(back.liabilities, Money(cents: 35_000))
        let shown = try await transactionCount(card.id, core)
        XCTAssertEqual(shown, 2, "including it brings back everything synced meanwhile")
        let allUncategorized = try await core.uncategorizedCount()
        XCTAssertEqual(allUncategorized, 4)
    }

    func testExcludedTransactionsLeaveCategoryCountsAndTransferMatching() async throws {
        let core = try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: Secrets(),
                                 network: bridge, clock: clock)
        try await core.loadSampleData()
        let s = core.store
        func txn(_ id: String, _ acct: String, _ cents: Int64) -> TransactionRecord {
            TransactionRecord(id: id, accountId: acct, sfinTxnId: id, postedAt: Self.start, transactedAt: nil,
                              amountCents: cents, description: "PAYMENT", payee: nil, memo: nil, pending: false,
                              categoryId: nil, categorySource: nil, isTransfer: false, transferGroupId: nil,
                              extraJson: nil, createdAt: 1, updatedAt: 1)
        }
        // Checking pays the Visa: a transfer pair, unless the Visa is excluded.
        try s.saveTransaction(txn("pay-out", "acct-chk", -50_000))
        try s.saveTransaction(txn("pay-in", "acct-visa", 50_000))

        let before = try await core.categoryTransactionCounts()
        try await core.setAccountStatus(accountId: "acct-visa", status: .excluded)
        let after = try await core.categoryTransactionCounts()
        XCTAssertEqual(after["interest"], nil, "the Visa's interest charge no longer counts")
        XCTAssertEqual(before["interest"], 1)
        XCTAssertEqual(after["groceries"], before["groceries"], "checking's counts are untouched")

        let paired = try await core.detectTransfers()
        XCTAssertEqual(paired, 0, "an excluded account can't turn a real payment into a transfer")
        let payment = try s.findTransaction(accountId: "acct-chk", sfinTxnId: "pay-out")
        XCTAssertEqual(payment?.isTransfer, false)
    }

    func testAnExcludedMortgageLeavesPropertyEquityAlone() async throws {
        let core = try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: Secrets(),
                                 network: bridge, clock: clock)
        try await core.loadSampleData()
        try await core.setAccountStatus(accountId: "acct-mtg", status: .excluded)
        let home = try await core.properties().first
        XCTAssertEqual(home?.linkedDebt, .zero)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.securedDebt, .zero)
        XCTAssertEqual(netWorth.realEstateEquity, Money(cents: 52_000_000))
    }

    // MARK: Paused

    func testPausedAccountStopsSyncingKeepsCountingAndCatchesUpOnResume() async throws {
        let core = try await syncedCore()
        let checking = try await account("Everyday Checking", core)
        let pausedAt = try XCTUnwrap(checking.balanceDate)
        try await core.setAccountStatus(accountId: checking.id, status: .paused)

        bridge.accounts[0].balanceCents = 250_000
        for _ in 0..<3 { clock.advance(days: 10); _ = try await core.syncNow() }

        let paused = try await account("Everyday Checking", core)
        XCTAssertEqual(paused.balance, Money(cents: 100_000), "a paused account holds its last balance")
        XCTAssertEqual(paused.balanceDate, pausedAt)
        let pausedTxns = try await transactionCount(checking.id, core)
        XCTAssertEqual(pausedTxns, 1)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.liquid, Money(cents: 100_000), "and still counts")

        // Resume: the next fetch reaches back to where checking left off, not
        // just to the connection's last sync (which kept running for the card).
        try await core.setAccountStatus(accountId: checking.id, status: .active)
        clock.advance(days: 1)
        _ = try await core.syncNow()
        XCTAssertEqual(bridge.starts.last, pausedAt - SyncEngine.overlap)
        let resumed = try await account("Everyday Checking", core)
        XCTAssertEqual(resumed.balance, Money(cents: 250_000))

        // The catch-up is spent: the sync after that is back to normal.
        let lastSync = clock.now()
        clock.advance(days: 1)
        _ = try await core.syncNow()
        XCTAssertEqual(bridge.starts.last, lastSync - SyncEngine.overlap)
    }

    func testOnlyBankAccountsCanPause() async throws {
        let core = try await syncedCore()
        let id = try await core.addManualAccount(name: "Car", accountClass: .investment,
                                                 balance: Money(cents: 1), asOf: Self.start)
        do {
            try await core.setAccountStatus(accountId: id, status: .paused)
            XCTFail("a manual account doesn't sync")
        } catch TTMError.invalidOperation {}
        try await core.setAccountStatus(accountId: id, status: .excluded)
        let car = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(car?.status, .excluded)
    }

    // MARK: Restoring a deleted account

    func testRestoringADeletedAccountRefetchesTheFullBackfill() async throws {
        let core = try await syncedCore()
        let checking = try await account("Everyday Checking", core)
        try await core.deleteAccount(accountId: checking.id)
        clock.advance(days: 5)
        _ = try await core.syncNow()
        XCTAssertEqual(bridge.starts.last, clock.now() - 5 * Self.day - SyncEngine.overlap)

        try await core.restoreAccount(accountId: checking.id)
        clock.advance(days: 1)
        _ = try await core.syncNow()
        XCTAssertEqual(bridge.starts.last, clock.now() - SyncEngine.defaultBackfill)
    }

    func testCatchUpNeverReachesPastTheBackfill() {
        let now: UnixTime = 1_700_000_000
        XCTAssertEqual(SyncEngine.windowStart(lastSyncedAt: nil, resyncFrom: nil, now: now),
                       now - SyncEngine.defaultBackfill)
        XCTAssertEqual(SyncEngine.windowStart(lastSyncedAt: now - 100, resyncFrom: nil, now: now),
                       now - 100 - SyncEngine.overlap)
        XCTAssertEqual(SyncEngine.windowStart(lastSyncedAt: now - 100, resyncFrom: 0, now: now),
                       now - SyncEngine.defaultBackfill)
        XCTAssertEqual(SyncEngine.windowStart(lastSyncedAt: now - 100, resyncFrom: now, now: now),
                       now - 100 - SyncEngine.overlap, "a catch-up never narrows the window")
    }

    // MARK: Holding new accounts

    func testNewAccountsCanBeHeldAsExcluded() async throws {
        let core = try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: Secrets(),
                                 network: bridge, clock: clock)
        try await core.setHoldsNewAccounts(true)
        let holds = try await core.holdsNewAccounts()
        XCTAssertTrue(holds)
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        let first = try await core.syncNow()
        XCTAssertEqual(first.heldAccounts, 0, "a connection's first sync takes everything")
        let initial = try await core.accounts()
        XCTAssertTrue(initial.allSatisfy { $0.status == .active })

        bridge.accounts.append(.init(id: "jnt", name: "Joint Savings", balanceCents: 500_000))
        clock.advance(days: 1)
        let second = try await core.syncNow()
        XCTAssertEqual(second.heldAccounts, 1)
        let joint = try await account("Joint Savings", core)
        XCTAssertEqual(joint.status, .excluded)
        XCTAssertEqual(joint.balance, Money(cents: 500_000), "held accounts still sync")
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.liquid, Money(cents: 100_000))
    }

    func testNewAccountsCountByDefault() async throws {
        let core = try await syncedCore()
        let holds = try await core.holdsNewAccounts()
        XCTAssertFalse(holds)
        bridge.accounts.append(.init(id: "jnt", name: "Joint Savings", balanceCents: 500_000))
        let outcome = try await core.syncNow()
        XCTAssertEqual(outcome.heldAccounts, 0)
        let joint = try await account("Joint Savings", core)
        XCTAssertEqual(joint.status, .active)
    }

    // MARK: Migration

    func testTheOldExcludedClassBecomesTheExcludedStatus() throws {
        let path = dir.appendingPathComponent("old.db").path
        let queue = try DatabaseQueue(path: path)
        try TTMCore.Database.migrator(through: "v4_uncat_index").migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO connections (id, name, keychain_ref, status, created_at) VALUES ('c', 'C', 'k', 'ok', 1);
                INSERT INTO accounts (id, connection_id, sfin_account_id, name, currency, class, balance_cents, created_at)
                VALUES ('a1', 'c', 's1', 'Work card', 'USD', 'excluded', 100, 1),
                       ('a2', 'c', 's2', 'Checking', 'USD', 'liquid', 100, 1);
                """)
        }
        try queue.close()

        let store = Store(try TTMCore.Database(path: path))
        let rows = try store.allAccounts().sorted { $0.id < $1.id }
        XCTAssertEqual(rows.map(\.status), ["excluded", "active"])
        XCTAssertEqual(rows.map(\.accountClass), ["unclassified", "liquid"])
    }
}
