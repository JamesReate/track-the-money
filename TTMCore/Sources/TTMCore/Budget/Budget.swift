import Foundation

// The monthly budget (docs/plans/MONTHLY_BUDGET_PLAN.md): expected income
// minus big bills and the savings goal is the everyday budget; category plans
// (with carry-over) and confirmed purchases come out of it, and what's left
// unplanned is splurge room. Pure: callers pass every input.

/// A calendar month with its stable key ("2026-11"), supplied by the app.
public struct BudgetPeriod: Equatable, Sendable {
    public let key: String
    public let span: MonthSpan
    public init(key: String, span: MonthSpan) { self.key = key; self.span = span }
}

/// A category as the budget sees it.
public struct BudgetCategory: Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: String?
    public init(id: String, name: String, color: String?) { self.id = id; self.name = name; self.color = color }
}

/// A plan amount stored for a category from `month` on, until a later row.
public struct StoredPlan: Equatable, Sendable {
    public let month: String
    public let categoryId: String
    public let amount: Money
    public init(month: String, categoryId: String, amount: Money) {
        self.month = month; self.categoryId = categoryId; self.amount = amount
    }
}

/// Something the user checked with "Can I afford it?" and saved (D6).
public struct PlannedPurchase: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable, CaseIterable {
        /// Shown, but doesn't reduce splurge room.
        case tentative
        /// Counts as planned: splurge room shrinks now.
        case confirmed
        /// Spent; its transaction now counts through the category.
        case bought
        case dropped
    }
    public let id: String
    public let month: String
    public let label: String
    public let amount: Money
    public let categoryId: String?
    public let status: Status
    public let transactionId: String?
    public let createdAt: UnixTime
    public init(id: String, month: String, label: String, amount: Money, categoryId: String?,
                status: Status, transactionId: String?, createdAt: UnixTime) {
        self.id = id; self.month = month; self.label = label; self.amount = amount; self.categoryId = categoryId
        self.status = status; self.transactionId = transactionId; self.createdAt = createdAt
    }
    public var isOpen: Bool { status == .tentative || status == .confirmed }
}

/// One line of everyday spending: a planned category, or "Everything else".
public struct BudgetRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let color: String?
    public let plan: Money
    /// Signed: last month's leftover (or overspend) when carry is on.
    public let carry: Money
    public let carryOn: Bool
    public let spent: Money
    /// Confirmed purchases not bought yet that belong to this row.
    public let reserved: Money
    /// Spent in each of the last 3 complete months, most recent first.
    public let history: [Money]
    /// The "Use $X" suggestion: the median of `history`, rounded up to $10.
    public let suggested: Money
    /// Everything else: the categories it gathers (no plan of their own).
    public let members: [String]

    public var isEverythingElse: Bool { id == Budget.everythingElseId }
    /// What this row may spend this month.
    public var available: Money { plan + carry }
    public var left: Money { available - spent }
    /// How far spending runs ahead of an even pace (negative: behind).
    public func aheadOfPace(_ pace: Double) -> Money {
        Money(cents: spent.cents - Int64((Double(max(0, available.cents)) * pace).rounded()))
    }
}

public struct BudgetMonth: Equatable, Sendable {
    public let period: BudgetPeriod
    /// Share of the month gone, 0...1.
    public let pace: Double
    public let income: IncomeMonth
    public let bills: ExpectedMonth
    public let savingsGoal: Money
    /// Σ signed carry over the rows.
    public let carriedIn: Money
    public let rows: [BudgetRow]
    /// This month's purchases still tentative or confirmed, then bought ones.
    public let purchases: [PlannedPurchase]
    /// Open purchases saved for earlier months: offer to move them here.
    public let earlierOpen: [PlannedPurchase]
    /// This month's everyday charges (no bills), newest first.
    public let charges: [RecurringCharge]
    /// Fewer than two months of spending to learn plans from.
    public let needsMoreHistory: Bool

    public var everydayBudget: Money { income.counted - bills.total - savingsGoal + carriedIn }
    public var everydaySpent: Money { rows.reduce(.zero) { $0 + $1.spent } }
    public var plannedTotal: Money { rows.reduce(.zero) { $0 + $1.plan } }
    public var openConfirmed: Money {
        purchases.filter { $0.status == .confirmed }.reduce(.zero) { $0 + $1.amount }
    }
    public var tentativeTotal: Money {
        purchases.filter { $0.status == .tentative }.reduce(.zero) { $0 + $1.amount }
    }
    /// Plans (or spending past them) plus confirmed purchases with no row.
    public var committed: Money {
        let rowsCommitted = rows.reduce(Money.zero) { $0 + max(max(.zero, $1.available), $1.spent + $1.reserved) }
        let loose = purchases.filter { $0.status == .confirmed && $0.categoryId == nil }.reduce(Money.zero) { $0 + $1.amount }
        return rowsCommitted + loose
    }
    /// Unplanned money; negative when spending or purchases overrun the plans.
    public var splurgeRoom: Money { everydayBudget - committed }
    public var leftThisMonth: Money { everydayBudget - everydaySpent - openConfirmed }
    /// Planned spending not spent yet (for the month bar).
    public var plannedToSpend: Money {
        rows.reduce(Money.zero) { $0 + max(.zero, max(.zero, $1.available) - $1.spent - $1.reserved) } + openConfirmed
    }

    /// The row a category's spending lands in.
    public func row(for categoryId: String?) -> BudgetRow? {
        guard let categoryId else { return nil }
        return rows.first { $0.id == categoryId } ?? rows.first { $0.isEverythingElse && $0.members.contains(categoryId) }
    }

    /// "Can I afford it?" (D6): draw on the category's remaining plan, then
    /// splurge room, then this month's savings goal.
    public func afford(_ amount: Money, categoryId: String?) -> AffordCheck {
        let row = row(for: categoryId)
        let categoryRoom = row.map { max(.zero, $0.available - $0.spent - $0.reserved) } ?? .zero
        let fromCategory = min(amount, categoryRoom)
        var rest = amount - fromCategory
        let fromRoom = min(rest, max(.zero, splurgeRoom))
        rest = rest - fromRoom
        let fromSavings = min(rest, max(.zero, savingsGoal))
        let short = rest - fromSavings
        let verdict: AffordCheck.Verdict = short.cents > 0 ? .notThisMonth : fromSavings.cents > 0 ? .trimSavings : .yes
        return AffordCheck(amount: amount, rowId: row?.id, rowName: row?.name, fromCategory: fromCategory,
                           fromRoom: fromRoom, fromSavings: fromSavings, short: short, verdict: verdict,
                           roomAfter: splurgeRoom - fromRoom)
    }

    /// Charges this month that could be a purchase being bought: within ±20%
    /// of its amount, in its row when it has a category, not linked to another
    /// purchase. Closest amount first.
    public func matches(for purchase: PlannedPurchase) -> [RecurringCharge] {
        let linked = Set(purchases.compactMap(\.transactionId))
        let rowId = row(for: purchase.categoryId)?.id
        let tolerance = Double(purchase.amount.cents) * 0.2
        return charges.filter { c in
            !linked.contains(c.transactionId)
                && abs(Double(c.amount.cents - purchase.amount.cents)) <= tolerance
                && (rowId == nil || row(for: c.categoryId)?.id == rowId || (rowId == Budget.everythingElseId && row(for: c.categoryId) == nil))
        }.sorted { abs($0.amount.cents - purchase.amount.cents) < abs($1.amount.cents - purchase.amount.cents) }
    }
}

public struct AffordCheck: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable { case yes, trimSavings, notThisMonth }
    public let amount: Money
    public let rowId: String?
    public let rowName: String?
    public let fromCategory: Money
    public let fromRoom: Money
    public let fromSavings: Money
    public let short: Money
    public let verdict: Verdict
    /// Splurge room left if bought.
    public let roomAfter: Money
}

public enum Budget {
    /// The row id for categories with no plan of their own (and uncategorized).
    public static let everythingElseId = "everything-else"
    /// A default plan under this rolls into Everything else.
    static let smallPlan: Int64 = 2_500
    static let lookbackMonths = 3

    public struct Inputs: Sendable {
        /// The month being budgeted.
        public var current: BudgetPeriod
        /// Earlier months, most recent first: at least 3 for plan defaults, and
        /// back to `startedKey` for carry-over.
        public var previous: [BudgetPeriod]
        public var now: UnixTime
        public var income: IncomeMonth
        public var bills: ExpectedMonth
        /// Outflows (no transfers, income or transfer categories) covering
        /// `previous` and `current`; bills are taken out here by merchant.
        public var charges: [RecurringCharge]
        /// Leaf spending categories, in display order.
        public var categories: [BudgetCategory]
        public var plans: [StoredPlan]
        public var carryOff: Set<String>
        public var purchases: [PlannedPurchase]
        public var savingsGoal: Money
        /// The first budgeted month; carry starts after it.
        public var startedKey: String

        public init(current: BudgetPeriod, previous: [BudgetPeriod], now: UnixTime, income: IncomeMonth,
                    bills: ExpectedMonth, charges: [RecurringCharge], categories: [BudgetCategory],
                    plans: [StoredPlan], carryOff: Set<String>, purchases: [PlannedPurchase],
                    savingsGoal: Money, startedKey: String) {
            self.current = current; self.previous = previous; self.now = now; self.income = income
            self.bills = bills; self.charges = charges; self.categories = categories; self.plans = plans
            self.carryOff = carryOff; self.purchases = purchases; self.savingsGoal = savingsGoal
            self.startedKey = startedKey
        }
    }

    /// Merchants that are big bills: their charges are not everyday spending.
    static func billKeys(_ bills: ExpectedMonth) -> Set<String> {
        Set((bills.upcoming + bills.paid).map(\.key))
    }

    /// Everyday spending by category id (nil: uncategorized) within a month.
    static func spendByCategory(_ charges: [RecurringCharge], in span: MonthSpan, billKeys: Set<String>) -> [String?: Int64] {
        var out: [String?: Int64] = [:]
        for c in charges where span.contains(c.at) && !billKeys.contains(MerchantKey.of(c.label)) {
            out[c.categoryId, default: 0] += c.amount.cents
        }
        return out
    }

    static func roundUpToTen(_ cents: Int64) -> Int64 { cents <= 0 ? 0 : ((cents + 999) / 1_000) * 1_000 }

    /// Plans for a first budgeted month: each category's median month over the
    /// lookback (bills excluded), rounded up to $10; small ones and
    /// uncategorized spending pool into Everything else.
    public static func defaultPlans(charges: [RecurringCharge], previous: [MonthSpan], bills: ExpectedMonth,
                                    categories: [BudgetCategory]) -> [String: Money] {
        let lookback = Array(previous.prefix(lookbackMonths))
        let keys = billKeys(bills)
        let months = lookback.map { spendByCategory(charges, in: $0, billKeys: keys) }
        let known = Set(categories.map(\.id))
        var plans: [String: Money] = [:]
        var other: Int64 = 0
        for cat in categories {
            let median = roundUpToTen(ExpectedExpenses.medianCents(months.map { $0[cat.id] ?? 0 }))
            if median >= smallPlan { plans[cat.id] = Money(cents: median) } else { other += median }
        }
        let loose = months.map { m in m.filter { k, _ in k.map { !known.contains($0) } ?? true }.values.reduce(0, +) }
        other += roundUpToTen(ExpectedExpenses.medianCents(loose))
        plans[everythingElseId] = Money(cents: other)
        return plans
    }

    /// Effective plans for a month: per category, the latest stored row at or
    /// before it. Categories with no row have no plan (they fall into
    /// Everything else).
    static func plans(for key: String, stored: [StoredPlan]) -> [String: Int64] {
        var latest: [String: (String, Int64)] = [:]
        for p in stored where p.month <= key {
            if let have = latest[p.categoryId], have.0 > p.month { continue }
            latest[p.categoryId] = (p.month, p.amount.cents)
        }
        return latest.mapValues(\.1)
    }

    /// Rows of one month: planned categories plus Everything else, with spend.
    struct MonthRows {
        var plan: [String: Int64]
        var spent: [String: Int64]
        var members: [String: [String]]
    }

    static func monthRows(plans: [String: Int64], spend: [String?: Int64], categories: [BudgetCategory]) -> MonthRows {
        let known = Set(categories.map(\.id))
        var plan: [String: Int64] = [everythingElseId: plans[everythingElseId] ?? 0]
        for c in categories where (plans[c.id] ?? 0) > 0 { plan[c.id] = plans[c.id] }
        var spent: [String: Int64] = [:]
        var members: [String: [String]] = [:]
        for (cat, cents) in spend {
            if let cat, known.contains(cat), plan[cat] != nil {
                spent[cat, default: 0] += cents
            } else {
                spent[everythingElseId, default: 0] += cents
            }
        }
        for c in categories where plan[c.id] == nil { members[everythingElseId, default: []].append(c.id) }
        return MonthRows(plan: plan, spent: spent, members: members)
    }

    public static func compute(_ input: Inputs) -> BudgetMonth {
        let keys = billKeys(input.bills)
        let current = input.current
        let span = current.span

        // Carry: walk budgeted months oldest → newest, up to (not including) this one.
        let walked = input.previous.filter { $0.key >= input.startedKey && $0.key < current.key }.reversed()
        var carry: [String: Int64] = [:]
        for period in walked {
            let rows = monthRows(plans: plans(for: period.key, stored: input.plans),
                                 spend: spendByCategory(input.charges, in: period.span, billKeys: keys),
                                 categories: input.categories)
            var next: [String: Int64] = [:]
            for (id, plan) in rows.plan where !input.carryOff.contains(id) {
                next[id] = plan + (carry[id] ?? 0) - (rows.spent[id] ?? 0)
            }
            carry = next
        }

        let thisPlans = plans(for: current.key, stored: input.plans)
        let rows = monthRows(plans: thisPlans, spend: spendByCategory(input.charges, in: span, billKeys: keys),
                             categories: input.categories)
        let purchases = input.purchases.filter { $0.month == current.key && $0.status != .dropped }
        let lookback = Array(input.previous.prefix(lookbackMonths))
        let pastSpend = lookback.map { spendByCategory(input.charges, in: $0.span, billKeys: keys) }
        let pastRows = lookback.map { p in
            monthRows(plans: thisPlans, spend: spendByCategory(input.charges, in: p.span, billKeys: keys),
                      categories: input.categories)
        }

        let byId = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = Dictionary(input.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [BudgetRow] = []
        for (id, plan) in rows.plan {
            let isOther = id == everythingElseId
            let history: [Money] = isOther
                ? pastRows.map { Money(cents: $0.spent[everythingElseId] ?? 0) }
                : pastSpend.map { Money(cents: $0[id] ?? 0) }
            let spent = rows.spent[id] ?? 0
            guard plan > 0 || spent > 0 || isOther else { continue }
            let reserved = purchases.filter { p in
                p.status == .confirmed && p.categoryId != nil
                    && (p.categoryId == id || (isOther && rows.plan[p.categoryId!] == nil))
            }.reduce(Int64(0)) { $0 + $1.amount.cents }
            let carryOn = !input.carryOff.contains(id)
            out.append(BudgetRow(
                id: id, name: isOther ? "Everything else" : byId[id]?.name ?? id,
                color: isOther ? nil : byId[id]?.color,
                plan: Money(cents: plan), carry: Money(cents: carryOn ? carry[id] ?? 0 : 0), carryOn: carryOn,
                spent: Money(cents: spent), reserved: Money(cents: reserved), history: history,
                suggested: Money(cents: roundUpToTen(ExpectedExpenses.medianCents(history.map(\.cents)))),
                members: rows.members[id] ?? []))
        }
        out.sort { a, b in
            if a.isEverythingElse != b.isEverythingElse { return b.isEverythingElse }
            if a.plan != b.plan { return a.plan > b.plan }
            return (order[a.id] ?? .max) < (order[b.id] ?? .max)
        }

        let month = span.end - span.start
        let pace = month > 0 ? min(1, max(0, Double(input.now - span.start) / Double(month))) : 0
        let charges = input.charges
            .filter { span.contains($0.at) && !keys.contains(MerchantKey.of($0.label)) }
            .sorted { ($0.at, $0.transactionId) > ($1.at, $1.transactionId) }
        let activeMonths = pastSpend.filter { !$0.isEmpty }.count
        return BudgetMonth(
            period: current, pace: pace, income: input.income, bills: input.bills,
            savingsGoal: input.savingsGoal, carriedIn: out.reduce(Money.zero) { $0 + $1.carry }, rows: out,
            purchases: purchases.sorted { a, b in
                if a.isOpen != b.isOpen { return a.isOpen }
                return (a.createdAt, a.id) < (b.createdAt, b.id)
            },
            earlierOpen: input.purchases.filter { $0.month < current.key && $0.isOpen }
                .sorted { ($0.month, $0.createdAt) < ($1.month, $1.createdAt) },
            charges: charges, needsMoreHistory: activeMonths < 2)
    }
}
