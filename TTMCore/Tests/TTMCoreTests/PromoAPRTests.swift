import XCTest
@testable import TTMCore

/// Credit-card promotional rates and the payoff outlook (ADR-0026).
final class PromoAPRTests: XCTestCase {
    private static let day: UnixTime = 86_400
    private static let today: UnixTime = 1_700_006_400 - 1_700_006_400 % 86_400   // a UTC midnight

    private final class Clock: TTMCore.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: UnixTime = PromoAPRTests.today + 10 * 3_600   // 10:00 on "today"
        func now() -> UnixTime { lock.lock(); defer { lock.unlock() }; return t }
        func advance(days: Int64) { lock.lock(); t += days * PromoAPRTests.day; lock.unlock() }
    }

    private struct NoSecrets: SecretStore {
        func read(ref: String) throws -> String? { nil }
        func write(_ value: String, ref: String) throws {}
        func delete(ref: String) throws {}
    }

    private struct NoNetwork: NetworkClient {
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { throw TTMError.network("offline") }
        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { throw TTMError.network("offline") }
    }

    private var dir: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-promo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = Clock()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func core() throws -> LocalCore {
        try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: NoSecrets(),
                      network: NoNetwork(), clock: clock)
    }

    private func card(_ core: LocalCore, _ name: String, owed: Int64, apr: Int? = 2_299) async throws -> String {
        let id = try await core.addManualAccount(name: name, accountClass: .creditCard,
                                                 balance: Money(cents: owed), asOf: Self.today)
        if let apr { try await core.setAccountAPR(accountId: id, aprBps: apr) }
        return id
    }

    private func summary(_ id: String, _ core: LocalCore) async throws -> AccountSummary {
        let found = try await core.accounts().first { $0.id == id }
        return try XCTUnwrap(found)
    }

    // MARK: Setting a promo

    func testPromoIsTheEffectiveRateUntilItEndsThenTheRegularRate() async throws {
        let core = try core()
        let id = try await card(core, "Balance transfer card", owed: 500_000)
        let ends = Self.today + 30 * Self.day
        try await core.setPromoAPR(accountId: id, promo: PromoRate(aprBps: 0, endsOn: ends))

        var visa = try await summary(id, core)
        XCTAssertEqual(visa.promo, PromoRate(aprBps: 0, endsOn: ends))
        XCTAssertEqual(visa.aprBps, 2_299, "the regular rate is kept alongside")
        XCTAssertEqual(visa.effectiveAprBps, 0)

        clock.advance(days: 30)   // the promo's last day: still on
        visa = try await summary(id, core)
        XCTAssertEqual(visa.effectiveAprBps, 0, "a promo runs through its whole end day")

        clock.advance(days: 1)
        visa = try await summary(id, core)
        XCTAssertEqual(visa.effectiveAprBps, 2_299)
        XCTAssertEqual(visa.promo?.isActive(at: clock.now()), false, "kept, but over")
        let outlook = try await core.promoOutlook()
        XCTAssertTrue(outlook.payoffs.isEmpty, "an ended promo has nothing left to beat")
    }

    func testPromoIsForCreditCardsWithASaneRateAndAFutureEnd() async throws {
        let core = try core()
        let loan = try await core.addManualAccount(name: "Car loan", accountClass: .securedDebt,
                                                   balance: Money(cents: 1), asOf: Self.today)
        let id = try await card(core, "Card", owed: 1)
        let refusals: [(String, PromoRate)] = [
            (loan, PromoRate(aprBps: 0, endsOn: Self.today + Self.day)),
            (id, PromoRate(aprBps: 10_001, endsOn: Self.today + Self.day)),
            (id, PromoRate(aprBps: 0, endsOn: Self.today - Self.day)),
        ]
        for (account, promo) in refusals {
            do {
                try await core.setPromoAPR(accountId: account, promo: promo)
                XCTFail("expected refusal of \(promo) on \(account)")
            } catch TTMError.invalidOperation {}
        }
        // Ending today is fine — it still applies until midnight.
        try await core.setPromoAPR(accountId: id, promo: PromoRate(aprBps: 0, endsOn: Self.today))
        try await core.setPromoAPR(accountId: id, promo: nil)
        let cleared = try await summary(id, core)
        XCTAssertNil(cleared.promo)
        XCTAssertEqual(cleared.effectiveAprBps, 2_299)
    }

    func testReclassifyingHidesThePromo() async throws {
        let core = try core()
        let id = try await card(core, "Card", owed: 1)
        try await core.setPromoAPR(accountId: id, promo: PromoRate(aprBps: 0, endsOn: Self.today + Self.day))
        try await core.setAccountClass(accountId: id, accountClass: .unsecuredDebt)
        let loan = try await summary(id, core)
        XCTAssertNil(loan.promo)
        XCTAssertEqual(loan.effectiveAprBps, 2_299)
    }

    // MARK: Payoff outlook

    func testCashCoversTheEarliestPromosFirst() async throws {
        let core = try core()
        _ = try await core.addManualAccount(name: "Checking", accountClass: .liquid,
                                            balance: Money(cents: 600_000), asOf: Self.today)
        let soon = try await card(core, "Soon", owed: 400_000)
        let later = try await card(core, "Later", owed: 300_000, apr: nil)
        let noPromo = try await card(core, "Plain", owed: 900_000)
        _ = noPromo
        try await core.setPromoAPR(accountId: later, promo: PromoRate(aprBps: 0, endsOn: Self.today + 365 * Self.day))
        try await core.setPromoAPR(accountId: soon, promo: PromoRate(aprBps: 0, endsOn: Self.today + 89 * Self.day))

        let outlook = try await core.promoOutlook()
        XCTAssertEqual(outlook.liquid, Money(cents: 600_000))
        XCTAssertEqual(outlook.payoffs.map(\.accountName), ["Soon", "Later"], "earliest end first; no-promo cards left out")
        XCTAssertEqual(outlook.totalDue, Money(cents: 700_000))
        XCTAssertEqual(outlook.shortfall, Money(cents: 100_000))

        let first = outlook.payoffs[0]
        XCTAssertTrue(first.covered)
        XCTAssertEqual(first.daysLeft, 90, "today through the 89th day after")
        XCTAssertEqual(first.monthsLeft, 3)
        XCTAssertEqual(first.monthlyToClear, Money(cents: 133_334), "rounded up so it really clears")
        XCTAssertEqual(first.interestPerMonthAfter, Money(cents: 7_663), "$4,000 × 22.99% ÷ 12")

        let second = outlook.payoffs[1]
        XCTAssertFalse(second.covered)
        XCTAssertEqual(second.dueByThen, Money(cents: 700_000))
        XCTAssertEqual(second.shortfall, Money(cents: 100_000))
        XCTAssertEqual(second.monthsLeft, 12)
        XCTAssertEqual(second.monthlyToClear, Money(cents: 25_000))
        XCTAssertNil(second.interestPerMonthAfter, "no regular rate set")
    }

    func testExcludedAndPaidOffCardsAndExcludedCashAreLeftOut() async throws {
        let core = try core()
        let savings = try await core.addManualAccount(name: "Joint savings", accountClass: .liquid,
                                                      balance: Money(cents: 1_000_000), asOf: Self.today)
        let work = try await card(core, "Work card", owed: 200_000)
        let paid = try await card(core, "Paid off", owed: 0)
        let mine = try await card(core, "Mine", owed: 50_000)
        for id in [work, paid, mine] {
            try await core.setPromoAPR(accountId: id, promo: PromoRate(aprBps: 0, endsOn: Self.today + 60 * Self.day))
        }
        try await core.setAccountStatus(accountId: work, status: .excluded)
        try await core.setAccountStatus(accountId: savings, status: .excluded)

        let outlook = try await core.promoOutlook()
        XCTAssertEqual(outlook.payoffs.map(\.accountName), ["Mine"])
        XCTAssertEqual(outlook.liquid, .zero, "excluded cash doesn't count either")
        XCTAssertEqual(outlook.shortfall, Money(cents: 50_000))
    }

    func testMonthsLeftRounding() {
        XCTAssertEqual(PromoMath.monthsLeft(daysAfterToday: 0), 1)
        XCTAssertEqual(PromoMath.monthsLeft(daysAfterToday: 30), 1)
        XCTAssertEqual(PromoMath.monthsLeft(daysAfterToday: 31), 2)
        XCTAssertEqual(PromoMath.monthsLeft(daysAfterToday: 365), 12)
        XCTAssertEqual(PromoMath.monthsLeft(daysAfterToday: 366), 13)
    }
}
