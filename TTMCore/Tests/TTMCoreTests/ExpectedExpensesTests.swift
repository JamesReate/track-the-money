import XCTest
@testable import TTMCore

/// Big recurring bills expected this month (ADR-0027).
final class ExpectedExpensesTests: XCTestCase {
    private static let day: UnixTime = 86_400
    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// A UTC calendar month.
    private static func month(_ year: Int, _ month: Int) -> MonthSpan {
        let start = utc.date(from: DateComponents(year: year, month: month, day: 1))!
        let end = utc.date(byAdding: .month, value: 1, to: start)!
        return MonthSpan(start: Time.unix(start), end: Time.unix(end))
    }

    /// November 2026 is "this month"; Oct, Sep, Aug are the lookback.
    private let current = month(2026, 11)
    private let previous = [month(2026, 10), month(2026, 9), month(2026, 8)]

    private func on(_ span: MonthSpan, day d: Int, hour: Int64 = 12) -> UnixTime {
        span.start + Int64(d - 1) * Self.day + hour * 3_600
    }

    private func charge(_ label: String, _ dollars: Double, _ at: UnixTime, id: String? = nil) -> RecurringCharge {
        RecurringCharge(transactionId: id ?? "\(label)-\(at)", label: label,
                        amount: Money(cents: Int64((dollars * 100).rounded())), at: at,
                        accountName: "Checking", categoryId: nil)
    }

    /// The same bill on `day` of each lookback month.
    private func monthly(_ label: String, _ dollars: Double, day d: Int, months: [MonthSpan]? = nil) -> [RecurringCharge] {
        (months ?? previous).map { charge(label, dollars, on($0, day: d)) }
    }

    private func compute(_ charges: [RecurringCharge], now: UnixTime? = nil,
                         settings: ExpectedExpenseSettings = .standard,
                         dismissed: [DismissedExpense] = []) -> ExpectedMonth {
        ExpectedExpenses.compute(charges: charges, current: current, previous: previous,
                                 now: now ?? on(current, day: 5), settings: settings, dismissed: dismissed)
    }

    // MARK: Merchant keys

    func testMerchantKeyDropsNumbersPaymentPrefixesAndSuffixes() {
        XCTAssertEqual(MerchantKey.of("HOME DEPOT #412"), "HOME DEPOT")
        XCTAssertEqual(MerchantKey.of("ACH DEBIT STATE FARM 0042"), "STATE FARM")
        XCTAssertEqual(MerchantKey.of("NETFLIX.COM"), "NETFLIX")
        XCTAssertEqual(MerchantKey.of("SQ *BLUE BOTTLE COFFEE 1234"), "BLUE BOTTLE COFFEE")
        XCTAssertEqual(MerchantKey.of("Rocket Mortgage LLC 11/03"), MerchantKey.of("ROCKET MORTGAGE"))
        XCTAssertEqual(MerchantKey.of("BRIGHT HORIZONS FAMILY SOLUTIONS"), "BRIGHT HORIZONS FAMILY")
        XCTAssertEqual(MerchantKey.of("POS DEBIT"), "POS DEBIT", "all noise falls back to the words there are")
        XCTAssertEqual(MerchantKey.of("1234 5678"), "")
    }

    // MARK: Detection

    func testASteadyBillIsExpectedOnItsUsualDayThenKnockedOffWhenItArrives() {
        let history = monthly("STATE FARM INSURANCE", 186, day: 12)
        let before = compute(history)
        XCTAssertEqual(before.upcoming.map(\.name), ["STATE FARM INSURANCE"])
        let item = before.upcoming[0]
        XCTAssertEqual(item.key, "STATE FARM INSURANCE")
        XCTAssertEqual(item.expected, Money(cents: 18_600))
        XCTAssertEqual(item.expectedOn, on(current, day: 12))
        XCTAssertEqual(item.monthsSeen, 3)
        XCTAssertEqual(item.status, .upcoming)
        XCTAssertEqual(before.remainingTotal, Money(cents: 18_600))
        XCTAssertEqual(before.paidTotal, .zero)
        XCTAssertFalse(before.needsMoreHistory)

        let arrived = charge("ACH STATE FARM INSURANCE 99", 191.40, on(current, day: 11), id: "nov")
        let after = compute(history + [arrived], now: on(current, day: 11))
        XCTAssertTrue(after.upcoming.isEmpty)
        XCTAssertEqual(after.paid.first?.status,
                       .paid(amount: Money(cents: 19_140), on: on(current, day: 11), transactionId: "nov"))
        XCTAssertEqual(after.paidTotal, Money(cents: 19_140), "a paid item counts what was actually charged")
        XCTAssertEqual(after.total, Money(cents: 19_140))
    }

    func testOnlyChargesAtOrOverTheMinimumCount() {
        let history = monthly("COMCAST", 149.99, day: 3) + monthly("PG&E UTILITY", 150, day: 20)
        XCTAssertEqual(compute(history).upcoming.map(\.name), ["PG&E UTILITY"])
        let lower = compute(history, settings: ExpectedExpenseSettings(minimum: Money(cents: 10_000)))
        XCTAssertEqual(lower.upcoming.map(\.name), ["COMCAST", "PG&E UTILITY"])
    }

    func testABillNeedsTwoOfTheLookbackMonths() {
        let once = [charge("DENTIST", 300, on(previous[1], day: 9))]
        XCTAssertTrue(compute(once).upcoming.isEmpty)
        let twice = once + [charge("DENTIST", 300, on(previous[2], day: 9))]
        XCTAssertEqual(compute(twice).upcoming.first?.monthsSeen, 2, "two of three months, even if it stopped")
    }

    func testWithATwoMonthLookbackItMustBeInBoth() {
        let settings = ExpectedExpenseSettings(lookbackMonths: 2)
        let septAndAug = [charge("GYM", 200, on(previous[1], day: 4)), charge("GYM", 200, on(previous[2], day: 4))]
        XCTAssertTrue(compute(septAndAug, settings: settings).upcoming.isEmpty, "August is outside a 2-month lookback")
        let octAndSept = [charge("GYM", 200, on(previous[0], day: 4)), charge("GYM", 200, on(previous[1], day: 4))]
        XCTAssertEqual(compute(octAndSept, settings: settings).upcoming.first?.lookbackMonths, 2)
    }

    func testFrequentShoppingIsNotABill() {
        let weekly = previous.flatMap { m in [2, 9, 16].map { charge("COSTCO WHOLESALE", 210, on(m, day: $0)) } }
        XCTAssertTrue(compute(weekly).upcoming.isEmpty)
    }

    func testAnOddChargeDoesNotHideASteadyBillAndTheLatestAmountIsExpected() {
        let history = [
            charge("TOYOTA FINANCIAL", 412, on(previous[2], day: 15)),
            charge("TOYOTA FINANCIAL", 900, on(previous[1], day: 15)),   // a one-off payoff chunk
            charge("TOYOTA FINANCIAL", 425, on(previous[0], day: 15)),
        ]
        let item = compute(history).upcoming.first
        XCTAssertEqual(item?.monthsSeen, 2)
        XCTAssertEqual(item?.expected, Money(cents: 42_500), "bills change; expect the latest similar one")
    }

    func testAnItemPastItsDayReadsLateAfterTwoDaysGrace() {
        let history = monthly("BRIGHT HORIZONS", 1_650, day: 3)
        XCTAssertEqual(compute(history, now: on(current, day: 5, hour: 11)).upcoming.first?.status, .upcoming)
        XCTAssertEqual(compute(history, now: on(current, day: 6)).upcoming.first?.status, .late)
    }

    func testABillDueOnTheFirstPaidAtTheEndOfLastMonthCountsAsPaid() {
        // Due around the 1st; November's was paid Oct 30, alongside October's own on Oct 1.
        let history = monthly("BRIGHT HORIZONS", 1_650, day: 1)
            + [charge("BRIGHT HORIZONS", 1_650, on(previous[0], day: 30), id: "early")]
        let month = compute(history, now: on(current, day: 10))
        XCTAssertTrue(month.upcoming.isEmpty, "not late: it came in early")
        XCTAssertEqual(month.paid.first?.status,
                       .paid(amount: Money(cents: 165_000), on: on(previous[0], day: 30), transactionId: "early"))

        // A bill due mid-month isn't knocked off by last month's late payment.
        let midMonth = monthly("STATE FARM", 186, day: 15) + [charge("STATE FARM", 186, on(previous[0], day: 30))]
        XCTAssertEqual(compute(midMonth, now: on(current, day: 10)).upcoming.count, 1)
    }

    func testASmallChargeFromTheSameMerchantDoesNotKnockOffTheBill() {
        let history = monthly("ROCKET MORTGAGE", 2_450, day: 1)
        let fee = charge("ROCKET MORTGAGE", 25, on(current, day: 2))
        let month = compute(history + [fee])
        XCTAssertEqual(month.upcoming.count, 1)
        XCTAssertTrue(month.paid.isEmpty)
    }

    func testRemovedMerchantsAreNotExpectedAndAreListed() {
        let history = monthly("SMILE ORTHODONTICS", 250, day: 8) + monthly("STATE FARM", 186, day: 12)
        let removed = DismissedExpense(key: "SMILE ORTHODONTICS", name: "SMILE ORTHODONTICS", dismissedAt: 1)
        let month = compute(history, dismissed: [removed])
        XCTAssertEqual(month.upcoming.map(\.key), ["STATE FARM"])
        XCTAssertEqual(month.dismissed, [removed])
    }

    func testOneMonthOfHistoryIsNotEnough() {
        let month = compute([charge("RENT", 2_000, on(previous[0], day: 1))])
        XCTAssertTrue(month.needsMoreHistory)
        XCTAssertTrue(month.upcoming.isEmpty)
    }

    func testTheExpectedDayStopsAtTheMonthsEnd() {
        // Charged on the 31st of Oct and Aug, and the 30th of Sep; November has 30 days.
        let history = [charge("LANDLORD", 2_000, on(previous[0], day: 31)),
                       charge("LANDLORD", 2_000, on(previous[1], day: 30)),
                       charge("LANDLORD", 2_000, on(previous[2], day: 31))]
        let item = compute(history).upcoming.first
        XCTAssertNotNil(item)
        XCTAssertLessThan(item!.expectedOn, current.end)
        XCTAssertGreaterThanOrEqual(item!.expectedOn, on(current, day: 30, hour: 0))
    }

    func testComingUpIsOrderedByExpectedDay() {
        let history = monthly("B LATE BILL", 300, day: 25) + monthly("A EARLY BILL", 300, day: 7)
        XCTAssertEqual(compute(history).upcoming.map(\.name), ["A EARLY BILL", "B LATE BILL"])
    }
}

/// Expected expenses through the facade: what counts, removals, settings.
final class ExpectedExpensesFacadeTests: XCTestCase {
    private static let day: UnixTime = 86_400
    // 2026-11-05 12:00 UTC.
    private static let now: UnixTime = 1_793_880_000 - 1_793_880_000 % 86_400 + 12 * 3_600

    private struct Clock: TTMCore.Clock { func now() -> UnixTime { ExpectedExpensesFacadeTests.now } }
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

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-expected-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func core() throws -> LocalCore {
        try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: NoSecrets(),
                      network: NoNetwork(), clock: Clock())
    }

    /// UTC months around `now`: the current one and the three before it.
    private func months() -> (MonthSpan, [MonthSpan]) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Time.date(Self.now)))!
        func span(_ offset: Int) -> MonthSpan {
            let s = cal.date(byAdding: .month, value: offset, to: start)!
            return MonthSpan(start: Time.unix(s), end: Time.unix(cal.date(byAdding: .month, value: 1, to: s)!))
        }
        return (span(0), [span(-1), span(-2), span(-3)])
    }

    private func expected(_ core: LocalCore) async throws -> ExpectedMonth {
        let (current, previous) = months()
        return try await core.expectedExpenses(current: current, previous: previous)
    }

    func testSampleDataExpectsItsSteadyBills() async throws {
        let core = try core()
        try await core.loadSampleData()
        let month = try await expected(core)
        let names = Set((month.upcoming + month.paid).map(\.name))
        for bill in ["ROCKET MORTGAGE", "TOYOTA FINANCIAL", "STATE FARM INSURANCE", "BRIGHT HORIZONS"] {
            XCTAssertTrue(names.contains(bill), "\(bill) missing from \(names)")
        }
        XCTAssertFalse(names.contains("WHOLE FOODS MARKET"), "small everyday spending isn't a bill")
        XCTAssertFalse(names.contains("DELTA AIR LINES"), "a one-off isn't a bill")
    }

    func testExcludedAccountsTransfersAndIncomeAreNotBills() async throws {
        let core = try core()
        try await core.loadSampleData()
        let s = core.store
        let (_, previous) = months()
        func txn(_ id: String, _ acct: String, _ label: String, _ cents: Int64, _ at: UnixTime,
                 transfer: Bool = false, category: String? = nil) -> TransactionRecord {
            TransactionRecord(id: id, accountId: acct, sfinTxnId: id, postedAt: at, transactedAt: nil,
                              amountCents: cents, description: label, payee: nil, memo: nil, pending: false,
                              categoryId: category, categorySource: category == nil ? nil : "manual",
                              isTransfer: transfer, transferGroupId: nil, extraJson: nil, createdAt: 1, updatedAt: 1)
        }
        for (i, m) in previous.enumerated() {
            let at = m.start + 10 * Self.day
            try s.saveTransaction(txn("visa-\(i)", "acct-visa", "AIRLINE CLUB DUES", -30_000, at))
            try s.saveTransaction(txn("xfer-\(i)", "acct-chk", "TRANSFER TO SAVINGS", -100_000, at, transfer: true))
            try s.saveTransaction(txn("refund-\(i)", "acct-chk", "PAYROLL CLAWBACK", -50_000, at, category: "income"))
        }
        let month = try await expected(core)
        let before = Set((month.upcoming + month.paid).map(\.name))
        XCTAssertTrue(before.contains("AIRLINE CLUB DUES"))
        XCTAssertFalse(before.contains("TRANSFER TO SAVINGS"))
        XCTAssertFalse(before.contains("PAYROLL CLAWBACK"))

        try await core.setAccountStatus(accountId: "acct-visa", status: .excluded)
        let after = try await expected(core)
        XCTAssertFalse((after.upcoming + after.paid).contains { $0.name == "AIRLINE CLUB DUES" })
    }

    func testRemovingAndRestoringAMerchantPersists() async throws {
        let core = try core()
        try await core.loadSampleData()
        let first = try await expected(core)
        let item = try XCTUnwrap((first.upcoming + first.paid).first { $0.name == "TOYOTA FINANCIAL" })

        try await core.dismissExpectedExpense(key: item.key, name: item.name)
        let reopened = try self.core()
        let removed = try await expected(reopened)
        XCTAssertFalse((removed.upcoming + removed.paid).contains { $0.key == item.key })
        XCTAssertEqual(removed.dismissed.map(\.name), ["TOYOTA FINANCIAL"])
        XCTAssertEqual(removed.dismissed.first?.dismissedAt, Self.now)

        try await reopened.restoreExpectedExpense(key: item.key)
        let restored = try await expected(reopened)
        XCTAssertTrue((restored.upcoming + restored.paid).contains { $0.key == item.key })
        XCTAssertTrue(restored.dismissed.isEmpty)
    }

    func testSettingsRoundTripAndRejectNonsense() async throws {
        let core = try core()
        let defaults = try await core.expectedExpenseSettings()
        XCTAssertEqual(defaults, ExpectedExpenseSettings(minimum: Money(cents: 15_000), lookbackMonths: 3))

        let custom = ExpectedExpenseSettings(minimum: Money(cents: 20_000), lookbackMonths: 2)
        try await core.setExpectedExpenseSettings(custom)
        let saved = try await core.expectedExpenseSettings()
        XCTAssertEqual(saved, custom)

        for bad in [ExpectedExpenseSettings(minimum: .zero), ExpectedExpenseSettings(lookbackMonths: 6)] {
            do {
                try await core.setExpectedExpenseSettings(bad)
                XCTFail("accepted \(bad)")
            } catch TTMError.invalidOperation {}
        }
        let unchanged = try await core.expectedExpenseSettings()
        XCTAssertEqual(unchanged, custom)
    }

    func testTheHigherMinimumDropsSmallerBills() async throws {
        let core = try core()
        try await core.loadSampleData()
        try await core.setExpectedExpenseSettings(ExpectedExpenseSettings(minimum: Money(cents: 50_000)))
        let month = try await expected(core)
        XCTAssertEqual(Set((month.upcoming + month.paid).map(\.name)), ["ROCKET MORTGAGE", "BRIGHT HORIZONS"])
    }

    func testTheDismissalTableIsAKnownMigration() {
        XCTAssertTrue(Database.knownMigrations.contains("v7_expected_expense_dismissals"))
    }
}
