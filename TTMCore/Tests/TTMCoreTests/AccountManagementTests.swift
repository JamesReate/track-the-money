import XCTest
@testable import TTMCore

/// Deleting accounts and manually tracked accounts (docs/plans/ACCOUNT_MANAGEMENT_PLAN.md).
final class AccountManagementTests: XCTestCase {
    private struct C: Clock { func now() -> UnixTime { 1_700_001_000 } }

    private final class Secrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        func read(ref: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return storage[ref] }
        func write(_ value: String, ref: String) throws { lock.lock(); storage[ref] = value; lock.unlock() }
        func delete(ref: String) throws { lock.lock(); storage[ref] = nil; lock.unlock() }
    }

    /// A bridge sharing one checking account with two transactions.
    private struct Bridge: NetworkClient {
        static let json = """
        { "errors": [], "accounts": [ {
            "id": "chk-1", "name": "Everyday Checking", "currency": "USD",
            "balance": "1250.00", "balance-date": 1700000000,
            "transactions": [
              { "id": "t1", "posted": 1699990000, "amount": "-52.30", "description": "CHEWY.COM" },
              { "id": "t2", "posted": 1699980000, "amount": "2000.00", "description": "PAYROLL" } ] } ] }
        """
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { Data(Self.json.utf8) }
        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data {
            Data("https://user:pass@bridge.test/simplefin".utf8)
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-acct-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func core() throws -> LocalCore {
        try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: Secrets(),
                      network: Bridge(), clock: C())
    }

    private let day: UnixTime = 86_400
    private let today: UnixTime = 1_699_920_000

    // MARK: Manual accounts

    func testManualAccountCountsInNetWorthAndHidesItsConnection() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "  Car  ", accountClass: .investment,
                                                 balance: Money(cents: 1_500_000), asOf: today)
        let account = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(account?.name, "Car")
        XCTAssertEqual(account?.source, .manual)
        XCTAssertEqual(account?.balanceDate, today)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.investments, Money(cents: 1_500_000))
        let connections = try await core.connections()
        XCTAssertTrue(connections.isEmpty, "the manual holder isn't a SimpleFIN connection")
        let series = try await core.netWorthSeries(from: nil, to: nil)
        XCTAssertEqual(series.last?.netWorth, Money(cents: 1_500_000))
    }

    func testManualDebtIsALiability() async throws {
        let core = try core()
        _ = try await core.addManualAccount(name: "Student loan", accountClass: .unsecuredDebt,
                                            balance: Money(cents: 2_000_000), asOf: today)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.liabilities, Money(cents: 2_000_000))
    }

    func testValueUpdatesFollowTheLatestDateAndReplaceTheSameDay() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "House fund", accountClass: .liquid,
                                                 balance: Money(cents: 100), asOf: today)
        try await core.setManualBalance(accountId: id, balance: Money(cents: 300), asOf: today + 10 * day)
        // Back-filling an older value doesn't move the current balance.
        try await core.setManualBalance(accountId: id, balance: Money(cents: 50), asOf: today - 10 * day)
        // Same day again replaces rather than duplicating.
        try await core.setManualBalance(accountId: id, balance: Money(cents: 350), asOf: today + 10 * day)

        let history = try await core.balanceHistory(accountId: id)
        XCTAssertEqual(history.map(\.balance.cents), [350, 100, 50])
        let account = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(account?.balance, Money(cents: 350))
        XCTAssertEqual(account?.balanceDate, today + 10 * day)

        try await core.deleteBalanceEntry(accountId: id, asOf: today + 10 * day)
        let after = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(after?.balance, Money(cents: 100))
        XCTAssertEqual(after?.balanceDate, today)
    }

    func testTheLastValueCannotBeDeleted() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "Cash", accountClass: .liquid,
                                                 balance: Money(cents: 100), asOf: today)
        do {
            try await core.deleteBalanceEntry(accountId: id, asOf: today)
            XCTFail("expected refusal")
        } catch TTMError.invalidOperation {}
        let history = try await core.balanceHistory(accountId: id)
        XCTAssertEqual(history.count, 1)
    }

    func testSyncedAccountsRefuseTypedValues() async throws {
        let core = try core()
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        _ = try await core.syncNow()
        let synced = try await core.accounts().first!
        do {
            try await core.setManualBalance(accountId: synced.id, balance: Money(cents: 1), asOf: today)
            XCTFail("expected refusal")
        } catch TTMError.invalidOperation {}
    }

    func testRenamingAManualAccountSetsItsName() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "Old", accountClass: .liquid,
                                                 balance: Money(cents: 1), asOf: today)
        try await core.renameAccount(accountId: id, name: "New")
        let account = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(account?.name, "New")
        XCTAssertEqual(account?.syncedName, "New")
        XCTAssertEqual(account?.isRenamed, false)
        try await core.renameAccount(accountId: id, name: "  ")   // no bank name to revert to
        let still = try await core.accounts().first { $0.id == id }
        XCTAssertEqual(still?.name, "New")
    }

    func testManualAccountsSurviveSyncAndDeleteOutright() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "Cash", accountClass: .liquid,
                                                 balance: Money(cents: 100), asOf: today)
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        let outcome = try await core.syncNow()
        XCTAssertEqual(outcome.connectionsFailed, 0, "the manual holder must not be synced")

        try await core.deleteAccount(accountId: id)
        let ids = try await core.accounts().map(\.id)
        XCTAssertFalse(ids.contains(id))
        XCTAssertTrue(try core.store.snapshots(accountId: id).isEmpty)
    }

    // MARK: Deleting synced accounts

    func testDeletedSyncedAccountIsNotReimported() async throws {
        let core = try core()
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        _ = try await core.syncNow()
        let checking = try await core.accounts().first!
        XCTAssertEqual(checking.source, .synced)

        try await core.deleteAccount(accountId: checking.id)
        _ = try await core.syncNow()

        let after = try await core.accounts().first { $0.id == checking.id }
        XCTAssertEqual(after?.archived, true)
        XCTAssertEqual(after?.balance, .zero)
        let txns = try await core.transactions(TxnQuery())
        XCTAssertTrue(txns.isEmpty)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.assets, .zero)

        try await core.restoreAccount(accountId: checking.id)
        _ = try await core.syncNow()
        let restored = try await core.accounts().first { $0.id == checking.id }
        XCTAssertEqual(restored?.archived, false)
        XCTAssertEqual(restored?.balance, Money(cents: 125_000))
        let back = try await core.transactions(TxnQuery())
        XCTAssertEqual(back.count, 2)
    }

    func testDeletingOneLegUnpairsTheOtherTransfer() async throws {
        let core = try core()
        try core.store.loadSample(now: C().now())
        let s = core.store
        try s.saveAccount(AccountRecord(id: "acct-other", connectionId: "demo-conn", sfinAccountId: "o",
            name: "Other", currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil,
            balanceCents: 0, availableCents: nil, balanceDate: nil, archived: false, createdAt: 1))
        func txn(_ id: String, _ acct: String, _ cents: Int64) -> TransactionRecord {
            TransactionRecord(id: id, accountId: acct, sfinTxnId: id, postedAt: 1, transactedAt: nil,
                              amountCents: cents, description: "XFER", payee: nil, memo: nil, pending: false,
                              categoryId: nil, categorySource: nil, isTransfer: false, transferGroupId: nil,
                              extraJson: nil, createdAt: 1, updatedAt: 1)
        }
        try s.saveTransaction(txn("x-out", "acct-chk", -500))
        try s.saveTransaction(txn("x-in", "acct-other", 500))
        try s.markTransferPair("x-out", "x-in", groupId: "g1", categoryId: "transfer", now: 1)

        try await core.deleteAccount(accountId: "acct-chk")
        let survivor = try s.findTransaction(accountId: "acct-other", sfinTxnId: "x-in")
        XCTAssertEqual(survivor?.isTransfer, false)
        XCTAssertNil(survivor?.transferGroupId)
        XCTAssertNil(survivor?.categoryId)
    }

    func testDeletingTheLastSampleAccountRemovesTheSampleConnection() async throws {
        let core = try core()
        try await core.loadSampleData()
        for account in try await core.accounts() { try await core.deleteAccount(accountId: account.id) }
        let accounts = try await core.accounts()
        XCTAssertTrue(accounts.isEmpty, "sample accounts delete outright, no tombstones")
        let connections = try await core.connections()
        XCTAssertTrue(connections.isEmpty)
        let properties = try await core.properties()
        XCTAssertEqual(properties.first?.linkedDebt, .zero, "the mortgage link went with its account")
    }

    // MARK: Interest rate & credit card class

    func testAPRIsSetOnDebtKeptBySyncAndClearable() async throws {
        let core = try core()
        try await core.claimSetupToken(Data("https://bridge.test/claim/x".utf8).base64EncodedString())
        _ = try await core.syncNow()
        let checking = try await core.accounts().first!
        do {
            try await core.setAccountAPR(accountId: checking.id, aprBps: 500)
            XCTFail("checking is not a debt")
        } catch TTMError.invalidOperation {}

        try await core.setAccountClass(accountId: checking.id, accountClass: .creditCard)
        try await core.setAccountAPR(accountId: checking.id, aprBps: 2299)
        try await core.setPromoAPR(accountId: checking.id, promo: PromoRate(aprBps: 0, endsOn: C().now()))
        _ = try await core.syncNow()
        let card = try await core.accounts().first { $0.id == checking.id }
        XCTAssertEqual(card?.aprBps, 2299, "sync never reports rates, so it must not erase one")
        XCTAssertEqual(card?.promo?.aprBps, 0, "nor a promo")

        do {
            try await core.setAccountAPR(accountId: checking.id, aprBps: 25_000)
            XCTFail("250% is a typo")
        } catch TTMError.invalidOperation {}

        try await core.setAccountAPR(accountId: checking.id, aprBps: nil)
        let cleared = try await core.accounts().first { $0.id == checking.id }
        XCTAssertNil(cleared?.aprBps)
    }

    func testCreditCardsAreUnsecuredDebtInTotalsAndTheDebtChart() async throws {
        let core = try core()
        let id = try await core.addManualAccount(name: "Card", accountClass: .creditCard,
                                                 balance: Money(cents: 40_000), asOf: today)
        try await core.setAccountAPR(accountId: id, aprBps: 1999)
        let netWorth = try await core.netWorthSummary()
        XCTAssertEqual(netWorth.unsecuredDebt, Money(cents: 40_000))
        XCTAssertEqual(netWorth.liabilities, Money(cents: 40_000))
        let debt = try await core.debtSeries(from: nil, to: nil)
        XCTAssertEqual(debt.last?.unsecured, Money(cents: 40_000))
        XCTAssertEqual(debt.last?.secured, .zero)
    }
}
