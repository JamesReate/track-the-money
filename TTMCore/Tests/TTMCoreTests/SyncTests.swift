import XCTest
@testable import TTMCore

private struct FixedClock: Clock {
    let t: UnixTime
    func now() -> UnixTime { t }
}

private final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func read(ref: String) throws -> String? { storage[ref] }
    func write(_ value: String, ref: String) throws { storage[ref] = value }
    func delete(ref: String) throws { storage[ref] = nil }
}

/// Returns a canned SimpleFIN response (also exercises the v1 JSON decoder).
private struct FakeSimpleFINClient: SimpleFINClient {
    let json: String
    func fetchAccounts(accessURL: URL, start: UnixTime?, end: UnixTime?, pending: Bool) async throws -> SFAccountSet {
        try JSONDecoder().decode(SFAccountSet.self, from: Data(json.utf8))
    }
}

final class SyncTests: XCTestCase {
    private let fixture = """
    {
      "errlist": [],
      "accounts": [
        {
          "id": "chk-1", "name": "Everyday Checking", "currency": "USD",
          "balance": "1250.00", "available-balance": "1200.00", "balance-date": 1700000000,
          "transactions": [
            { "id": "t1", "posted": 1699990000, "amount": "-52.30", "description": "CHEWY.COM ORDER", "payee": "CHEWY.COM" },
            { "id": "t2", "posted": 1699980000, "amount": "2000.00", "description": "PAYROLL", "payee": "ACME" }
          ]
        },
        {
          "id": "visa-1", "name": "VISA Signature", "currency": "USD",
          "balance": "-430.18", "balance-date": 1700000000,
          "transactions": [
            { "id": "t3", "posted": 1699970000, "amount": "-15.00", "description": "INTEREST CHARGE", "payee": "BANK" }
          ]
        }
      ]
    }
    """

    private func makeCore() throws -> (Store, SyncEngine, FakeSecretStore, FixedClock) {
        let db = try Database.inMemory()
        let store = Store(db)
        let clock = FixedClock(t: 1700001000)
        try DefaultData.seedIfEmpty(store, now: clock.now())
        let secrets = FakeSecretStore()
        let ref = "conn-test"
        try secrets.write("https://user:pass@beta-bridge.simplefin.org/simplefin", ref: ref)
        try store.saveConnection(ConnectionRecord(
            id: "c1", name: "Test", keychainRef: ref, sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: clock.now()
        ))
        let engine = SyncEngine(store: store, client: FakeSimpleFINClient(json: fixture), secrets: secrets, clock: clock)
        return (store, engine, secrets, clock)
    }

    func testSyncInsertsAccountsAndTransactions() async throws {
        let (store, engine, _, _) = try makeCore()
        let outcome = await engine.run()

        XCTAssertEqual(outcome.connectionsSucceeded, 1)
        XCTAssertEqual(outcome.connectionsFailed, 0)
        XCTAssertEqual(outcome.newTransactions, 3)

        let accounts = try store.allAccounts()
        XCTAssertEqual(accounts.count, 2)
        let visa = accounts.first { $0.sfinAccountId == "visa-1" }
        XCTAssertEqual(visa?.accountClass, AccountClass.unsecuredDebt.rawValue)   // smart default
        XCTAssertEqual(visa?.balanceCents, -43018)
    }

    func testSyncIsIdempotent() async throws {
        let (_, engine, _, _) = try makeCore()
        _ = await engine.run()
        let second = await engine.run()
        XCTAssertEqual(second.newTransactions, 0)   // re-sync inserts nothing new
    }

    func testRuleAppliesAtSyncTime() async throws {
        let (store, engine, _, clock) = try makeCore()
        let rule = Rule(id: "r-pets", name: "Pets", categoryId: "pets", priority: 10, enabled: true,
                        condition: Condition(op: .and, clauses: [
                            Clause(field: .description, match: .contains, value: "chewy")
                        ]))
        let json = String(data: try JSONEncoder().encode(rule.condition), encoding: .utf8)!
        try store.saveRuleRecord(RuleRecord(id: rule.id, name: rule.name, categoryId: rule.categoryId,
                                            priority: rule.priority, enabled: rule.enabled, conditions: json,
                                            createdAt: clock.now(), updatedAt: clock.now()))

        _ = await engine.run()

        let chewy = try store.transactionsForMatching(onlyUncategorized: false).first { $0.description.contains("CHEWY") }
        // Matched rows exclude manual; the CHEWY txn should now carry rule source.
        XCTAssertEqual(chewy?.categorySource, "rule:r-pets")
    }

    func testNetWorthFromSyncedData() async throws {
        let (store, engine, _, clock) = try makeCore()
        _ = await engine.run()

        // checking +1250.00 asset, visa 430.18 unsecured liability
        let core = NetWorth.summary(
            accounts: try store.allAccounts().compactMap { rec in
                guard let cls = AccountClass(rawValue: rec.accountClass) else { return nil }
                let cents = cls.contribution == .liability ? abs(rec.balanceCents) : rec.balanceCents
                return AccountBalance(accountClass: cls, balance: Money(cents: cents))
            },
            propertyValues: [],
            asOf: clock.now()
        )
        XCTAssertEqual(core.liquid.cents, 125_000)
        XCTAssertEqual(core.unsecuredDebt.cents, 43_018)
        XCTAssertEqual(core.netWorth.cents, 125_000 - 43_018)
    }
}
