import XCTest
@testable import TTMCore

private let day: UnixTime = 86_400
private let utc: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}()

private func month(_ year: Int, _ month: Int) -> MonthSpan {
    let start = utc.date(from: DateComponents(year: year, month: month, day: 1))!
    let end = utc.date(byAdding: .month, value: 1, to: start)!
    return MonthSpan(start: Time.unix(start), end: Time.unix(end))
}

private func on(_ span: MonthSpan, day d: Int, hour: Int64 = 12) -> UnixTime {
    span.start + Int64(d - 1) * day + hour * 3_600
}

private func money(_ dollars: Double) -> Money { Money(cents: Int64((dollars * 100).rounded())) }

private func item(_ label: String, _ dollars: Double, _ at: UnixTime, category: String? = nil,
                  id: String? = nil) -> RecurringCharge {
    RecurringCharge(transactionId: id ?? "\(label)-\(at)", label: label, amount: money(dollars), at: at,
                    accountName: "Checking", categoryId: category)
}

/// Expected income per payer (MONTHLY_BUDGET_PLAN D2).
final class ExpectedIncomeTests: XCTestCase {
    private let current = month(2026, 11)
    private let previous = [month(2026, 10), month(2026, 9), month(2026, 8)]

    private func compute(_ deposits: [RecurringCharge], now: UnixTime? = nil,
                         settings: [IncomeSourceSetting] = []) -> IncomeMonth {
        ExpectedIncome.compute(deposits: deposits, current: current, previous: previous,
                               now: now ?? on(current, day: 18), settings: settings)
    }

    /// Every 14 days from Aug 9: Nov gets the 1st, 15th and 29th.
    private func biweekly(through end: UnixTime, skipping: Set<Int> = []) -> [RecurringCharge] {
        var out: [RecurringCharge] = [], t = on(month(2026, 8), day: 9), n = 0
        while t <= end {
            if !skipping.contains(n) { out.append(item("PAYROLL ACME INC", 2_400, t)) }
            t += 14 * day; n += 1
        }
        return out
    }

    func testBiweeklyPayExpectsTwoOrThreeDepositsAndKnocksThemOff() throws {
        let now = on(current, day: 18)
        let income = compute(biweekly(through: now), now: now)
        let payroll = try XCTUnwrap(income.sources.first)
        XCTAssertEqual(payroll.mode, .regular)
        XCTAssertTrue(payroll.isSteady)
        XCTAssertEqual(payroll.slots.map(\.expectedOn), [1, 15, 29].map { on(current, day: $0) })
        XCTAssertEqual(payroll.slots.map(\.isLanded), [true, true, false])
        XCTAssertEqual(payroll.counted, money(7_200))
        XCTAssertEqual(payroll.landed, money(4_800))
        XCTAssertEqual(payroll.stillToCome, money(2_400))
        XCTAssertEqual(payroll.overdue, .zero)
    }

    func testALatePaycheckStillCountsAndShowsAsOverdue() throws {
        let now = on(current, day: 18)
        // Deposit #7 is Nov 15: it never came.
        let payroll = try XCTUnwrap(compute(biweekly(through: now, skipping: [7]), now: now).sources.first)
        XCTAssertEqual(payroll.slots[1].status, .late)
        XCTAssertEqual(payroll.counted, money(7_200), "expected income counts before it lands")
        XCTAssertEqual(payroll.overdue, money(2_400))
    }

    func testSemimonthlyPayLandsOnItsUsualDays() throws {
        let deposits = previous.flatMap { [item("SALARY", 3_000, on($0, day: 1)), item("SALARY", 3_000, on($0, day: 15))] }
            + [item("SALARY", 3_000, on(current, day: 1))]
        let salary = try XCTUnwrap(compute(deposits).sources.first)
        XCTAssertEqual(salary.slots.map(\.expectedOn), [on(current, day: 1), on(current, day: 15)])
        XCTAssertEqual(salary.slots[1].status, .late, "the 15th is three days gone on the 18th")
        XCTAssertEqual(salary.counted, money(6_000))
    }

    func testMonthlySalaryAndAnEarlyDepositForThisMonth() throws {
        // Paid on the 1st; November's came on Oct 30, a weekend shift.
        let deposits = [item("SALARY", 5_000, on(month(2026, 8), day: 1)), item("SALARY", 5_000, on(month(2026, 9), day: 1)),
                        item("SALARY", 5_000, on(month(2026, 10), day: 1)), item("SALARY", 5_000, on(month(2026, 10), day: 30))]
        let salary = try XCTUnwrap(compute(deposits).sources.first)
        XCTAssertEqual(salary.slots.count, 1)
        XCTAssertTrue(salary.slots[0].isLanded, "a deposit a couple of days early is this month's")
        XCTAssertEqual(salary.counted, money(5_000))
    }

    /// Contract work: amounts all over the place.
    private let contract: [RecurringCharge] = [
        item("NORTHWIND LLC", 2_000, on(month(2026, 8), day: 10)),
        item("NORTHWIND LLC", 900, on(month(2026, 9), day: 20)),
        item("NORTHWIND LLC", 1_500, on(month(2026, 10), day: 5)),
        item("NORTHWIND LLC", 500, on(month(2026, 10), day: 25)),
    ]

    func testIrregularPayIsNotBudgetedUntilChosen() throws {
        let source = try XCTUnwrap(compute(contract + [item("NORTHWIND LLC", 700, on(current, day: 3))]).sources.first)
        XCTAssertFalse(source.isSteady)
        XCTAssertEqual(source.mode, .notBudgeted)
        XCTAssertEqual(source.counted, money(700), "counts only once it lands")
        XCTAssertEqual(source.stillToCome, .zero)
        XCTAssertEqual(source.lowestMonth, money(900))
    }

    func testVariablePayCountsItsLowestMonthAndFlagsWhenItRunsLate() throws {
        let setting = IncomeSourceSetting(key: "NORTHWIND", name: "NORTHWIND LLC", mode: .variable)
        let nothing = try XCTUnwrap(compute(contract, now: on(current, day: 12), settings: [setting]).sources.first)
        XCTAssertEqual(nothing.estimate, money(900))
        XCTAssertEqual(nothing.usuallyOn, on(current, day: 10))
        XCTAssertEqual(nothing.counted, money(900))
        XCTAssertEqual(nothing.overdue, .zero, "a week's grace past its usual day")

        let partial = try XCTUnwrap(compute(contract + [item("NORTHWIND LLC", 400, on(current, day: 12))],
                                            now: on(current, day: 18), settings: [setting]).sources.first)
        XCTAssertEqual(partial.landed, money(400))
        XCTAssertEqual(partial.stillToCome, money(500))
        XCTAssertEqual(partial.overdue, money(500))

        let more = try XCTUnwrap(compute(contract + [item("NORTHWIND LLC", 1_200, on(current, day: 12))],
                                         settings: [setting]).sources.first)
        XCTAssertEqual(more.counted, money(1_200), "landing more than the estimate counts what landed")
        XCTAssertEqual(more.overdue, .zero)

        let typed = IncomeSourceSetting(key: "NORTHWIND", name: "NORTHWIND LLC", mode: .variable, estimate: money(1_100))
        XCTAssertEqual(compute(contract, settings: [typed]).sources.first?.counted, money(1_100))
    }

    func testARegularChoiceWhosePatternFadedReadsAsVariable() throws {
        let setting = IncomeSourceSetting(key: "NORTHWIND", name: "NORTHWIND LLC", mode: .regular)
        let source = try XCTUnwrap(compute(contract, settings: [setting]).sources.first)
        XCTAssertEqual(source.mode, .variable)
        XCTAssertTrue(source.isUserSet)
    }
}

/// The month's arithmetic, carry-over, purchases and the afford check.
final class BudgetTests: XCTestCase {
    private let nov = BudgetPeriod(key: "2026-11", span: month(2026, 11))
    private let previous = [BudgetPeriod(key: "2026-10", span: month(2026, 10)),
                            BudgetPeriod(key: "2026-09", span: month(2026, 9)),
                            BudgetPeriod(key: "2026-08", span: month(2026, 8))]
    private let categories = [BudgetCategory(id: "groceries", name: "Groceries", color: "#5E8C6A"),
                              BudgetCategory(id: "going-out", name: "Going Out", color: "#586E5A"),
                              BudgetCategory(id: "coffee", name: "Coffee", color: nil)]
    private lazy var now = on(nov.span, day: 15)

    /// Each lookback month: groceries $600, going out $300, coffee $20,
    /// uncategorized $50, rent $2,000 (a bill).
    private func history() -> [RecurringCharge] {
        previous.flatMap { p -> [RecurringCharge] in
            (1...4).map { item("SAFEWAY", 150, on(p.span, day: $0 * 6), category: "groceries") }
                + (1...3).map { item("BAR CENTRO", 100, on(p.span, day: $0 * 8), category: "going-out") }
                + [item("BLUE BOTTLE", 20, on(p.span, day: 3), category: "coffee"),
                   item("MYSTERY", 50, on(p.span, day: 4)),
                   item("RENT CO", 2_000, on(p.span, day: 1), category: "home")]
        }
    }

    /// November so far: groceries $300, going out $250, coffee $10, rent paid.
    private func november(extra: [RecurringCharge] = []) -> [RecurringCharge] {
        [item("SAFEWAY", 150, on(nov.span, day: 3), category: "groceries"),
         item("SAFEWAY", 150, on(nov.span, day: 10), category: "groceries"),
         item("BAR CENTRO", 100, on(nov.span, day: 5), category: "going-out"),
         item("BOWLERO", 150, on(nov.span, day: 12), category: "going-out"),
         item("BLUE BOTTLE", 10, on(nov.span, day: 6), category: "coffee"),
         item("RENT CO", 2_000, on(nov.span, day: 1), category: "home")] + extra
    }

    private func salary() -> IncomeMonth {
        let deposits = (previous.map(\.span) + [nov.span]).map { item("SALARY", 5_000, on($0, day: 1)) }
        return ExpectedIncome.compute(deposits: deposits, current: nov.span, previous: previous.map(\.span),
                                      now: now, settings: [])
    }

    private func bills(_ charges: [RecurringCharge]) -> ExpectedMonth {
        ExpectedExpenses.compute(charges: charges, current: nov.span, previous: previous.map(\.span), now: now,
                                 settings: .standard, dismissed: [])
    }

    private func budget(charges extra: [RecurringCharge] = [], plans: [StoredPlan]? = nil,
                        carryOff: Set<String> = [], purchases: [PlannedPurchase] = [],
                        started: String = "2026-11") -> BudgetMonth {
        let charges = history() + november(extra: extra)
        let bills = bills(charges)
        let defaults = Budget.defaultPlans(charges: charges, previous: previous.map(\.span), bills: bills,
                                           categories: categories)
        let stored = plans ?? defaults.map { StoredPlan(month: nov.key, categoryId: $0.key, amount: $0.value) }
        return Budget.compute(Budget.Inputs(
            current: nov, previous: previous, now: now, income: salary(), bills: bills, charges: charges,
            categories: categories, plans: stored, carryOff: carryOff, purchases: purchases,
            savingsGoal: money(500), startedKey: started))
    }

    private func purchase(_ id: String, _ dollars: Double, _ status: PlannedPurchase.Status,
                          category: String? = nil, month: String = "2026-11") -> PlannedPurchase {
        PlannedPurchase(id: id, month: month, label: id, amount: money(dollars), categoryId: category,
                        status: status, transactionId: nil, createdAt: 1)
    }

    func testDefaultPlansAreMediansWithBillsOutAndSmallOnesPooled() {
        let charges = history()
        let plans = Budget.defaultPlans(charges: charges, previous: previous.map(\.span), bills: bills(charges),
                                        categories: categories)
        XCTAssertEqual(plans["groceries"], money(600))
        XCTAssertEqual(plans["going-out"], money(300))
        XCTAssertNil(plans["coffee"], "under $25 a month pools into Everything else")
        XCTAssertEqual(plans[Budget.everythingElseId], money(70), "coffee $20 + uncategorized $50")
        XCTAssertNil(plans["home"], "rent is a bill, not a plan")
    }

    func testTheMonthAddsUp() throws {
        let b = budget()
        XCTAssertEqual(b.income.counted, money(5_000))
        XCTAssertEqual(b.bills.total, money(2_000))
        XCTAssertEqual(b.everydayBudget, money(2_500), "5,000 − 2,000 bills − 500 savings")
        XCTAssertEqual(b.rows.map(\.id), ["groceries", "going-out", Budget.everythingElseId])
        XCTAssertEqual(b.rows.map(\.spent), [money(300), money(250), money(10)], "rent isn't everyday spending")
        XCTAssertEqual(b.rows.last?.members, ["coffee"])
        XCTAssertEqual(b.everydaySpent, money(560))
        XCTAssertEqual(b.splurgeRoom, money(1_530), "2,500 − (600 + 300 + 70)")
        XCTAssertEqual(b.leftThisMonth, money(1_940))
        XCTAssertEqual(b.pace, 14.5 / 30, accuracy: 0.0001)
        let goingOut = try XCTUnwrap(b.rows.first { $0.id == "going-out" })
        XCTAssertEqual(goingOut.history, [money(300), money(300), money(300)])
        XCTAssertEqual(goingOut.suggested, money(300))
        XCTAssertEqual(goingOut.aheadOfPace(b.pace), money(105), "250 spent vs 145 by an even pace")
        XCTAssertFalse(b.charges.contains { $0.label == "RENT CO" })
    }

    func testOverspendingComesOutOfSplurgeRoomAndCanTakeItNegative() {
        let over = budget(charges: [item("THE ROSE ROOM", 200, on(nov.span, day: 14), category: "going-out")])
        XCTAssertEqual(over.rows.first { $0.id == "going-out" }?.spent, money(450))
        XCTAssertEqual(over.splurgeRoom, money(1_380), "150 over the plan comes out of the room")

        let wild = budget(charges: [item("JEWELER", 2_000, on(nov.span, day: 14), category: "going-out")])
        XCTAssertEqual(wild.splurgeRoom.cents, -42_000, "2,500 − (600 + 2,250 + 70): over plan, not clamped to zero")
    }

    func testCarryIsSignedAndOptional() throws {
        let plans = [StoredPlan(month: "2026-10", categoryId: "groceries", amount: money(500)),
                     StoredPlan(month: "2026-10", categoryId: "going-out", amount: money(400)),
                     StoredPlan(month: "2026-10", categoryId: Budget.everythingElseId, amount: money(70))]
        let b = budget(plans: plans, started: "2026-10")
        let groceries = try XCTUnwrap(b.rows.first { $0.id == "groceries" })
        let goingOut = try XCTUnwrap(b.rows.first { $0.id == "going-out" })
        XCTAssertEqual(groceries.plan, money(500), "November inherits October's plans")
        XCTAssertEqual(groceries.carry, money(-100), "October overspent by $100")
        XCTAssertEqual(goingOut.carry, money(100), "October left $100")
        XCTAssertEqual(goingOut.available, money(500))
        XCTAssertEqual(b.carriedIn, money(0), "+100 − 100 + (70 − 70)")
        XCTAssertEqual(b.everydayBudget, money(2_500))

        let off = budget(plans: plans, carryOff: ["groceries"], started: "2026-10")
        XCTAssertEqual(off.rows.first { $0.id == "groceries" }?.carry, .zero)
        XCTAssertEqual(off.carriedIn, money(100))
        XCTAssertEqual(off.everydayBudget, money(2_600), "carried money is still there to spend")

        let fresh = budget(plans: plans, started: "2026-11")
        XCTAssertEqual(fresh.carriedIn, .zero, "nothing carries into the first budgeted month")
    }

    func testPurchasesTentativeConfirmedAndBought() {
        let base = budget()
        let tentative = budget(purchases: [purchase("gift", 200, .tentative)])
        XCTAssertEqual(tentative.splurgeRoom, base.splurgeRoom, "tentative doesn't reduce the room")
        XCTAssertEqual(tentative.tentativeTotal, money(200))

        let confirmed = budget(purchases: [purchase("gift", 200, .confirmed)])
        XCTAssertEqual(confirmed.splurgeRoom, base.splurgeRoom - money(200))
        XCTAssertEqual(confirmed.leftThisMonth, base.leftThisMonth - money(200))

        // $100 out with $50 left in Going Out: only $50 more comes out of the room.
        let inPlan = budget(purchases: [purchase("show", 100, .confirmed, category: "going-out")])
        XCTAssertEqual(inPlan.rows.first { $0.id == "going-out" }?.reserved, money(100))
        XCTAssertEqual(inPlan.splurgeRoom, base.splurgeRoom - money(50))

        let bought = budget(purchases: [purchase("gift", 200, .bought), purchase("old", 50, .dropped)])
        XCTAssertEqual(bought.splurgeRoom, base.splurgeRoom, "a bought one counts through its transaction")
        XCTAssertEqual(bought.purchases.map(\.id), ["gift"], "dropped ones leave the month")

        let earlier = budget(purchases: [purchase("trip", 900, .confirmed, month: "2026-10")])
        XCTAssertEqual(earlier.earlierOpen.map(\.id), ["trip"])
        XCTAssertEqual(earlier.splurgeRoom, base.splurgeRoom, "October's purchase isn't November's")
    }

    func testAffordCheckDrawsOnThePlanThenRoomThenSavings() {
        let b = budget()   // room 1,530; savings 500; Going Out has 50 left
        let small = b.afford(money(40), categoryId: "going-out")
        XCTAssertEqual(small.verdict, .yes)
        XCTAssertEqual(small.fromCategory, money(40))
        XCTAssertEqual(small.fromRoom, .zero)

        let show = b.afford(money(120), categoryId: "going-out")
        XCTAssertEqual(show.fromCategory, money(50))
        XCTAssertEqual(show.fromRoom, money(70))
        XCTAssertEqual(show.roomAfter, money(1_460))

        let big = b.afford(money(2_000), categoryId: nil)
        XCTAssertEqual(big.verdict, .trimSavings)
        XCTAssertEqual(big.fromRoom, money(1_530))
        XCTAssertEqual(big.fromSavings, money(470))

        let huge = b.afford(money(3_000), categoryId: nil)
        XCTAssertEqual(huge.verdict, .notThisMonth)
        XCTAssertEqual(huge.short, money(970))

        XCTAssertEqual(b.afford(money(5), categoryId: "coffee").rowId, Budget.everythingElseId,
                       "a category without a plan draws on Everything else")
    }

    func testMatchesForAPurchaseAreCloseAmountsInItsRow() {
        let b = budget(charges: [item("TICKETMASTER", 95, on(nov.span, day: 13), category: "going-out", id: "tm"),
                                 item("SAFEWAY", 105, on(nov.span, day: 13), category: "groceries", id: "sw")])
        let show = purchase("show", 96, .confirmed, category: "going-out")
        XCTAssertEqual(b.matches(for: show).map(\.transactionId).first, "tm")
        XCTAssertFalse(b.matches(for: show).contains { $0.transactionId == "sw" })
        let any = purchase("gift", 96, .confirmed)
        XCTAssertTrue(b.matches(for: any).contains { $0.transactionId == "sw" })
    }
}

/// The budget through the facade, on sample data.
final class BudgetFacadeTests: XCTestCase {
    // 2026-11-05 12:00 UTC.
    private static let now: UnixTime = 1_793_880_000 - 1_793_880_000 % 86_400 + 12 * 3_600
    private struct Clock: TTMCore.Clock { func now() -> UnixTime { BudgetFacadeTests.now } }
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
            .appendingPathComponent("ttm-budget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func core() throws -> LocalCore {
        try LocalCore(dbPath: dir.appendingPathComponent("ttm.db").path, secrets: NoSecrets(),
                      network: NoNetwork(), clock: Clock())
    }

    /// `offset` 0 is November 2026, then the months before it.
    private func periods(from offset: Int = 0) -> [BudgetPeriod] {
        let nov = utc.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        return (0..<6).map { i in
            let s = utc.date(byAdding: .month, value: offset - i, to: nov)!
            let c = utc.dateComponents([.year, .month], from: s)
            return BudgetPeriod(key: String(format: "%04d-%02d", c.year!, c.month!),
                                span: MonthSpan(start: Time.unix(s), end: Time.unix(utc.date(byAdding: .month, value: 1, to: s)!)))
        }
    }

    /// Opening This Month before the first sync must not pin $0 plans for the month.
    func testEmptyStoreDoesNotPinPlansUntilThereIsHistory() async throws {
        let core = try core()
        let empty = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(empty.plannedTotal, .zero)
        try await core.loadSampleData()
        let later = try await core.budgetMonth(periods: periods())
        XCTAssertTrue(later.rows.contains { $0.name == "Groceries" && $0.plan.cents > 0 },
                      "\(later.rows.map { ($0.name, $0.plan.cents) })")
        XCTAssertEqual(later.rows.first { $0.isEverythingElse }?.carry ?? .zero, .zero)
    }

    func testSampleDataBudgetsOnDayOneAndPinsItsPlans() async throws {
        let core = try core()
        try await core.loadSampleData()
        let first = try await core.budgetMonth(periods: periods())
        XCTAssertFalse(first.needsMoreHistory)
        XCTAssertEqual(first.savingsGoal, Money(cents: 30_000))
        let names = first.rows.map(\.name)
        for name in ["Groceries", "Going Out", "Dining", "Pets"] { XCTAssertTrue(names.contains(name), "\(name) in \(names)") }
        XCTAssertEqual(first.rows.last?.isEverythingElse, true)
        let kids = try XCTUnwrap(first.rows.first { $0.id == "kids" })
        XCTAssertLessThan(kids.plan, Money(cents: 100_000), "Bright Horizons ($1,650) is a bill, not Kids' plan")

        let payroll = try XCTUnwrap(first.income.sources.first { $0.name.hasPrefix("PAYROLL") })
        XCTAssertEqual(payroll.mode, .regular)
        XCTAssertFalse(payroll.slots.isEmpty)
        let contract = try XCTUnwrap(first.income.sources.first { $0.name == "NORTHWIND LLC" })
        XCTAssertEqual(contract.mode, .variable)
        XCTAssertTrue(contract.isUserSet)
        XCTAssertGreaterThan(first.income.counted, first.bills.total)

        let stored = try core.store.budgetPlans()
        XCTAssertTrue(stored.allSatisfy { $0.month == "2026-11" })
        XCTAssertTrue(stored.contains { $0.categoryId == Budget.everythingElseId })
        let again = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(again.rows, first.rows, "the pinned plans don't drift")
        let started = try core.store.setting(Store.budgetStartedKey)
        XCTAssertEqual(started, "2026-11")
    }

    func testPlansCarryIntoTheNextMonth() async throws {
        let core = try core()
        try await core.loadSampleData()
        _ = try await core.budgetMonth(periods: periods())
        try await core.setCategoryPlan(month: "2026-11", categoryId: "going-out", plan: Money(cents: 40_000))
        let nov = try await core.budgetMonth(periods: periods())
        let novRow = try XCTUnwrap(nov.rows.first { $0.id == "going-out" })
        XCTAssertEqual(novRow.plan, Money(cents: 40_000))

        let dec = try await core.budgetMonth(periods: periods(from: 1))
        let decRow = try XCTUnwrap(dec.rows.first { $0.id == "going-out" })
        XCTAssertEqual(decRow.plan, Money(cents: 40_000), "December inherits November's plan")
        XCTAssertEqual(decRow.carry, novRow.plan - novRow.spent)

        try await core.setCategoryCarry(categoryId: "going-out", carry: false)
        let decOff = try await core.budgetMonth(periods: periods(from: 1))
        XCTAssertEqual(decOff.rows.first { $0.id == "going-out" }?.carry, .zero)
        XCTAssertEqual(decOff.rows.first { $0.id == "going-out" }?.carryOn, false)
    }

    func testSettingsAndIncomeModesRoundTrip() async throws {
        let core = try core()
        try await core.loadSampleData()
        try await core.setSavingsGoal(Money(cents: 75_000))
        try await core.setIncomeMode(key: "NORTHWIND", name: "NORTHWIND LLC", mode: .variable, estimate: Money(cents: 120_000))
        var b = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(b.savingsGoal, Money(cents: 75_000))
        XCTAssertEqual(b.income.sources.first { $0.key == "NORTHWIND" }?.estimate, Money(cents: 120_000))

        try await core.setIncomeMode(key: "NORTHWIND", name: "NORTHWIND LLC", mode: nil, estimate: nil)
        b = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(b.income.sources.first { $0.key == "NORTHWIND" }?.mode, .notBudgeted, "back to the default")

        for bad in [{ try await core.setSavingsGoal(Money(cents: -1)) },
                    { try await core.setCategoryPlan(month: "2026-11", categoryId: "groceries", plan: Money(cents: -5)) }] {
            do { try await bad(); XCTFail("accepted a negative amount") } catch TTMError.invalidOperation {}
        }
    }

    func testPurchasesSaveConfirmBuyAndMove() async throws {
        let core = try core()
        try await core.loadSampleData()
        let base = try await core.budgetMonth(periods: periods())
        let gift = try await core.savePlannedPurchase(month: "2026-11", label: " Gift ", amount: Money(cents: 30_000),
                                                       categoryId: nil, status: .tentative)
        XCTAssertEqual(gift.label, "Gift")
        var b = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(b.splurgeRoom, base.splurgeRoom)

        try await core.updatePlannedPurchase(id: gift.id, status: .confirmed, transactionId: nil, month: nil)
        b = try await core.budgetMonth(periods: periods())
        XCTAssertEqual(b.splurgeRoom, base.splurgeRoom - Money(cents: 30_000))

        try await core.updatePlannedPurchase(id: gift.id, status: .confirmed, transactionId: nil, month: "2026-12")
        b = try await core.budgetMonth(periods: periods())
        XCTAssertTrue(b.purchases.isEmpty, "moved to December")
        let dec = try await core.budgetMonth(periods: periods(from: 1))
        XCTAssertEqual(dec.purchases.map(\.id), [gift.id])

        try await core.updatePlannedPurchase(id: gift.id, status: .bought, transactionId: "txn-t1", month: nil)
        let bought = try core.store.plannedPurchases().first
        XCTAssertEqual(bought?.status, .bought)
        XCTAssertEqual(bought?.transactionId, "txn-t1")

        do {
            _ = try await core.savePlannedPurchase(month: "2026-11", label: "x", amount: .zero, categoryId: nil, status: .tentative)
            XCTFail("accepted $0")
        } catch TTMError.invalidOperation {}
    }

    func testTheBudgetTablesAreAKnownMigration() {
        XCTAssertTrue(Database.knownMigrations.contains("v8_monthly_budget"))
    }
}
