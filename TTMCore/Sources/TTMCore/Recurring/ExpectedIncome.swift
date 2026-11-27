import Foundation

// Income expected this month, per payer (docs/plans/MONTHLY_BUDGET_PLAN.md D2).
// Pure: callers pass deposits already gated to the Income category, local
// month boundaries and `now`.

/// How a payer's deposits count toward the month.
public enum IncomeMode: String, Equatable, Sendable, CaseIterable {
    /// Steady pay (salary): each expected deposit, counted before it lands.
    case regular
    /// Contract or irregular work: one cautious monthly estimate.
    case variable
    /// Counts only once it lands (bonuses, one-offs).
    case notBudgeted = "not_budgeted"
}

/// The user's choice for one payer, stored per profile.
public struct IncomeSourceSetting: Equatable, Sendable {
    public let key: String
    public let name: String
    public let mode: IncomeMode
    /// Variable mode: a typed monthly amount instead of the lowest recent month.
    public let estimate: Money?
    public init(key: String, name: String, mode: IncomeMode, estimate: Money? = nil) {
        self.key = key; self.name = name; self.mode = mode; self.estimate = estimate
    }
}

/// One expected deposit from a regular payer.
public struct IncomeSlot: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case upcoming
        /// Past its date by the grace period and still not in.
        case late
        case landed(amount: Money, on: UnixTime, transactionId: String)
    }
    public let expected: Money
    public let expectedOn: UnixTime
    public let status: Status
    public var isLanded: Bool { if case .landed = status { return true } else { return false } }
    /// What it adds to the month: the actual amount once in.
    public var monthAmount: Money {
        if case .landed(let amount, _, _) = status { return amount }
        return expected
    }
}

/// One payer's month.
public struct IncomeSourceMonth: Equatable, Sendable, Identifiable {
    /// `MerchantKey` of the payer; settings are stored under it.
    public let key: String
    public let name: String
    /// The mode in effect (a stored `regular` whose pattern faded reads as `variable`).
    public let mode: IncomeMode
    /// Whether the user chose the mode (false: the default from detection).
    public let isUserSet: Bool
    /// Steady deposits were found: regular is on offer.
    public let isSteady: Bool
    /// Regular: the expected deposits this month, earliest first.
    public let slots: [IncomeSlot]
    /// Variable: the monthly amount counted at minimum.
    public let estimate: Money
    /// Variable: around when it usually lands.
    public let usuallyOn: UnixTime?
    /// Deposits in so far this month (plus an early one matched to a slot).
    public let landed: Money
    /// What counts toward the month's income.
    public let counted: Money
    /// Counted but not in yet.
    public let stillToCome: Money
    /// The part of `stillToCome` that is overdue.
    public let overdue: Money
    /// Lowest and middle monthly totals over the lookback, for the options screen.
    public let lowestMonth: Money
    public let typicalMonth: Money

    public var id: String { key }
}

public struct IncomeMonth: Equatable, Sendable {
    /// Payers seen in the lookback or this month: counted ones first, then by name.
    public let sources: [IncomeSourceMonth]
    public var counted: Money { sources.reduce(.zero) { $0 + $1.counted } }
    public var landed: Money { sources.reduce(.zero) { $0 + $1.landed } }
    public var stillToCome: Money { sources.reduce(.zero) { $0 + $1.stillToCome } }
    public var overdue: Money { sources.reduce(.zero) { $0 + $1.overdue } }
    public init(sources: [IncomeSourceMonth]) { self.sources = sources }
}

public enum ExpectedIncome {
    static let lookbackMonths = 3
    /// At least this share of a payer's deposits must be similar for it to be steady.
    static let steadyShare = 0.8
    /// Regular pay is late this many days after its date; variable gets longer.
    static let regularGraceDays: Int64 = 2
    static let variableGraceDays: Int64 = 7

    /// - Parameters:
    ///   - deposits: money in, categorized as Income, as positive amounts.
    ///   - previous: complete months before `current`, most recent first.
    public static func compute(deposits: [RecurringCharge], current: MonthSpan, previous: [MonthSpan],
                               now: UnixTime, settings: [IncomeSourceSetting]) -> IncomeMonth {
        let lookback = Array(previous.prefix(lookbackMonths))
        let earlyCutoff = current.start - ExpectedExpenses.earlyDays * Time.secondsPerDay
        var history: [String: [(deposit: RecurringCharge, month: Int)]] = [:]
        var thisMonth: [String: [RecurringCharge]] = [:]
        var justBefore: [String: [RecurringCharge]] = [:]
        var latestLabel: [String: (UnixTime, String)] = [:]
        for d in deposits {
            let key = MerchantKey.of(d.label)
            guard !key.isEmpty else { continue }
            if current.contains(d.at) {
                thisMonth[key, default: []].append(d)
            } else if let month = lookback.firstIndex(where: { $0.contains(d.at) }) {
                history[key, default: []].append((d, month))
                if d.at >= earlyCutoff { justBefore[key, default: []].append(d) }
            } else {
                continue
            }
            if (latestLabel[key]?.0 ?? .min) < d.at { latestLabel[key] = (d.at, d.label) }
        }
        let byKey = Dictionary(settings.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var sources: [IncomeSourceMonth] = []
        for key in Set(history.keys).union(thisMonth.keys) {
            let seen = history[key] ?? []
            let here = (thisMonth[key] ?? []).sorted { $0.at < $1.at }
            let monthTotals = lookback.indices.map { m in
                seen.filter { $0.month == m }.reduce(Int64(0)) { $0 + $1.deposit.amount.cents }
            }
            let lowest = Money(cents: monthTotals.min() ?? 0)
            let typical = Money(cents: ExpectedExpenses.medianCents(monthTotals))
            let pattern = steadyPattern(seen, lookback: lookback, current: current)
            let setting = byKey[key]
            var mode = setting?.mode ?? (pattern == nil ? .notBudgeted : .regular)
            if mode == .regular && pattern == nil { mode = .variable }
            let name = setting?.name ?? latestLabel[key]?.1 ?? key
            let landedHere = here.reduce(Money.zero) { $0 + $1.amount }

            var slots: [IncomeSlot] = []
            var landed = landedHere, counted = Money.zero, stillToCome = Money.zero, overdue = Money.zero
            var estimate = Money.zero
            var usuallyOn: UnixTime? = nil
            switch mode {
            case .regular:
                let (expected, dates) = pattern!
                let early = (justBefore[key] ?? []).filter { d in dates.contains { d.at >= $0 - ExpectedExpenses.earlyDays * Time.secondsPerDay } }
                var open = Array(dates.indices)
                var matched: [Int: RecurringCharge] = [:]
                var extra = Money.zero
                for d in (early + here).sorted(by: { $0.at < $1.at }) {
                    let fits = open.filter { d.at >= dates[$0] - ExpectedExpenses.earlyDays * Time.secondsPerDay }
                    if Double(d.amount.cents) >= ExpectedExpenses.arrivalFraction * Double(expected.cents),
                       let best = fits.min(by: { abs(d.at - dates[$0]) < abs(d.at - dates[$1]) }) {
                        matched[best] = d
                        open.removeAll { $0 == best }
                    } else if current.contains(d.at) {
                        extra = extra + d.amount
                    }
                }
                slots = dates.indices.map { i in
                    if let d = matched[i] {
                        return IncomeSlot(expected: expected, expectedOn: dates[i],
                                          status: .landed(amount: d.amount, on: d.at, transactionId: d.transactionId))
                    }
                    let late = now > dates[i] + regularGraceDays * Time.secondsPerDay
                    return IncomeSlot(expected: expected, expectedOn: dates[i], status: late ? .late : .upcoming)
                }
                landed = slots.reduce(Money.zero) { $0 + ($1.isLanded ? $1.monthAmount : .zero) } + extra
                counted = slots.reduce(Money.zero) { $0 + $1.monthAmount } + extra
                stillToCome = counted - landed
                overdue = slots.filter { $0.status == .late }.reduce(Money.zero) { $0 + $1.expected }
            case .variable:
                estimate = setting?.estimate ?? lowest
                let offsets = seen.map { $0.deposit.at - lookback[$0.month].start }
                usuallyOn = offsets.isEmpty ? nil : min(current.start + ExpectedExpenses.medianCents(offsets), current.end - 1)
                counted = max(estimate, landedHere)
                stillToCome = counted - landedHere
                if stillToCome.cents > 0, let on = usuallyOn, now > on + variableGraceDays * Time.secondsPerDay {
                    overdue = stillToCome
                }
            case .notBudgeted:
                counted = landedHere
            }
            sources.append(IncomeSourceMonth(
                key: key, name: name, mode: mode, isUserSet: setting != nil, isSteady: pattern != nil,
                slots: slots, estimate: estimate, usuallyOn: usuallyOn, landed: landed, counted: counted,
                stillToCome: stillToCome, overdue: overdue, lowestMonth: lowest, typicalMonth: typical))
        }
        sources.sort { a, b in
            if (a.counted.cents > 0) != (b.counted.cents > 0) { return a.counted.cents > 0 }
            if a.counted != b.counted { return a.counted.cents > b.counted.cents }
            return (a.name, a.key) < (b.name, b.key)
        }
        return IncomeMonth(sources: sources)
    }

    /// A steady payer's expected amount and this month's expected dates, or nil.
    ///
    /// Steady: similar deposits (within ±35% of the median) in at least 2
    /// lookback months, making up at least 80% of the payer's deposits.
    /// Biweekly pay (every gap 13–15 days) steps 14 days from the last deposit,
    /// so a month gets 2 or 3; otherwise the month's usual number of deposits
    /// each land on their usual day (monthly, or semimonthly on the 1st and 15th).
    static func steadyPattern(_ seen: [(deposit: RecurringCharge, month: Int)], lookback: [MonthSpan],
                              current: MonthSpan) -> (Money, [UnixTime])? {
        guard !seen.isEmpty else { return nil }
        let median = ExpectedExpenses.medianCents(seen.map(\.deposit.amount.cents))
        let similar = seen.filter { abs(Double($0.deposit.amount.cents - median)) <= ExpectedExpenses.similarity * Double(median) }
            .sorted { $0.deposit.at < $1.deposit.at }
        let months = Set(similar.map(\.month))
        guard median > 0, months.count >= min(2, lookback.count), lookback.count > 0,
              Double(similar.count) >= steadyShare * Double(seen.count) else { return nil }
        let expected = similar.last!.deposit.amount
        let day = Time.secondsPerDay

        let gaps = zip(similar.dropFirst(), similar).map { ($0.deposit.at - $1.deposit.at) / day }
        if similar.count >= 3, gaps.allSatisfy({ (13...15).contains($0) }) {
            var dates: [UnixTime] = []
            var t = similar.last!.deposit.at + 14 * day
            while t < current.end {
                if t >= current.start { dates.append(t) }
                t += 14 * day
            }
            return (expected, dates)
        }

        var perMonth: [Int: [RecurringCharge]] = [:]
        for s in similar { perMonth[s.month, default: []].append(s.deposit) }
        let count = Int(ExpectedExpenses.medianCents(perMonth.values.map { Int64($0.count) }))
        let typicalMonths = perMonth.filter { $0.value.count == count }
        let dates = (0..<count).map { i -> UnixTime in
            let offsets = typicalMonths.map { m, ds in ds.sorted { $0.at < $1.at }[i].at - lookback[m].start }
            return min(current.start + ExpectedExpenses.medianCents(offsets), current.end - 1)
        }
        return (expected, dates.sorted())
    }
}
