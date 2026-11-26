import Foundation

// Big recurring bills expected this month, detected from the last few months
// (docs/plans/EXPECTED_EXPENSES_PLAN.md, ADR-0027). Pure: callers pass the
// charges, local month boundaries and `now`.

/// A calendar month as `[start, end)` in Unix seconds; the app computes these
/// in the user's time zone.
public struct MonthSpan: Equatable, Sendable {
    public let start: UnixTime
    public let end: UnixTime
    public init(start: UnixTime, end: UnixTime) { self.start = start; self.end = end }
    public func contains(_ t: UnixTime) -> Bool { t >= start && t < end }
}

/// How detection is tuned; stored per profile in `settings`.
public struct ExpectedExpenseSettings: Equatable, Sendable {
    /// A merchant's typical charge must be at least this.
    public var minimum: Money
    /// Complete months looked back over (2 or 3).
    public var lookbackMonths: Int

    public init(minimum: Money = Money(cents: 15_000), lookbackMonths: Int = 3) {
        self.minimum = minimum; self.lookbackMonths = lookbackMonths
    }
    public static let standard = ExpectedExpenseSettings()
    public static let minimumChoices: [Money] = [100, 150, 200, 250, 500].map { Money(cents: Int64($0) * 100) }
    public static let lookbackChoices = [2, 3]
}

/// One outflow, as detection sees it.
public struct RecurringCharge: Equatable, Sendable {
    public let transactionId: String
    /// Payee, else description: what the user recognizes.
    public let label: String
    /// Money out, as a positive amount.
    public let amount: Money
    /// Posted time, or transacted time for a pending charge.
    public let at: UnixTime
    public let accountName: String
    public let categoryId: String?
    public init(transactionId: String, label: String, amount: Money, at: UnixTime, accountName: String, categoryId: String?) {
        self.transactionId = transactionId; self.label = label; self.amount = amount; self.at = at
        self.accountName = accountName; self.categoryId = categoryId
    }
}

public struct ExpectedExpense: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        /// Not in yet and not overdue.
        case upcoming
        /// More than two days past its expected day and still not in.
        case late
        /// Arrived this month.
        case paid(amount: Money, on: UnixTime, transactionId: String)
    }
    /// `MerchantKey` — also the id removals are stored under.
    public let key: String
    /// The latest charge's payee or description.
    public let name: String
    /// The latest similar charge.
    public let expected: Money
    /// When it should land this month.
    public let expectedOn: UnixTime
    /// Lookback months it was charged in, out of `lookbackMonths`.
    public let monthsSeen: Int
    public let lookbackMonths: Int
    public let accountName: String
    public let categoryId: String?
    public let status: Status

    public var id: String { key }
    public var isPaid: Bool { if case .paid = status { return true } else { return false } }
    /// What it adds to this month: the actual amount once paid.
    public var monthAmount: Money {
        if case .paid(let amount, _, _) = status { return amount }
        return expected
    }
}

/// A merchant the user removed from expected expenses.
public struct DismissedExpense: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let dismissedAt: UnixTime
    public var id: String { key }
    public init(key: String, name: String, dismissedAt: UnixTime) {
        self.key = key; self.name = name; self.dismissedAt = dismissedAt
    }
}

/// The current month's big recurring bills.
public struct ExpectedMonth: Equatable, Sendable {
    /// Still to come, earliest expected first (late ones lead).
    public let upcoming: [ExpectedExpense]
    /// Arrived this month, earliest first.
    public let paid: [ExpectedExpense]
    public let dismissed: [DismissedExpense]
    public let settings: ExpectedExpenseSettings
    /// Fewer than two lookback months have any outflows: nothing can recur yet.
    public let needsMoreHistory: Bool

    public var paidTotal: Money { paid.reduce(.zero) { $0 + $1.monthAmount } }
    public var remainingTotal: Money { upcoming.reduce(.zero) { $0 + $1.expected } }
    public var total: Money { paidTotal + remainingTotal }
}

public enum ExpectedExpenses {
    /// Charges within this fraction of the median count as the same bill.
    static let similarity = 0.35
    /// At most this many charges per month seen; more is everyday shopping.
    static let maxChargesPerMonth = 1.5
    /// A charge this month at least this fraction of the expected amount means it arrived.
    static let arrivalFraction = 0.5
    /// Days past the expected day before an item reads as late.
    static let graceDays: Int64 = 2
    /// A charge this many days before its expected day still counts as this
    /// month's: a bill due on the 1st is often paid on the 30th or 31st.
    static let earlyDays: Int64 = 5

    /// - Parameters:
    ///   - charges: outflows covering `previous` and `current` (others are ignored).
    ///   - previous: complete months before `current`, most recent first; the
    ///     first `settings.lookbackMonths` are used.
    public static func compute(charges: [RecurringCharge], current: MonthSpan, previous: [MonthSpan],
                               now: UnixTime, settings: ExpectedExpenseSettings,
                               dismissed: [DismissedExpense]) -> ExpectedMonth {
        let lookback = Array(previous.prefix(max(1, settings.lookbackMonths)))
        let required = min(2, lookback.count)
        let dismissedKeys = Set(dismissed.map(\.key))

        var history: [String: [(charge: RecurringCharge, month: Int)]] = [:]
        var thisMonth: [String: [RecurringCharge]] = [:]
        var justBefore: [String: [RecurringCharge]] = [:]   // the last days of last month
        var activeMonths = Set<Int>()
        for charge in charges {
            let key = MerchantKey.of(charge.label)
            guard !key.isEmpty else { continue }
            if current.contains(charge.at) {
                thisMonth[key, default: []].append(charge)
            } else if let month = lookback.firstIndex(where: { $0.contains(charge.at) }) {
                if charge.at >= current.start - earlyDays * Time.secondsPerDay {
                    justBefore[key, default: []].append(charge)
                }
                history[key, default: []].append((charge, month))
                activeMonths.insert(month)
            }
        }

        var upcoming: [ExpectedExpense] = []
        var paid: [ExpectedExpense] = []
        for (key, seen) in history where !dismissedKeys.contains(key) {
            let monthsAny = Set(seen.map(\.month)).count
            guard Double(seen.count) <= maxChargesPerMonth * Double(monthsAny) else { continue }
            let median = medianCents(seen.map(\.charge.amount.cents))
            guard median >= settings.minimum.cents else { continue }
            let similar = seen.filter { abs(Double($0.charge.amount.cents - median)) <= similarity * Double(median) }
            let months = Set(similar.map(\.month)).count
            guard months >= required, required > 0 else { continue }

            let latest = similar.max { $0.charge.at < $1.charge.at }!.charge
            let offset = medianCents(similar.map { $0.charge.at - lookback[$0.month].start })
            let expectedOn = min(current.start + offset, current.end - 1)
            let early = (justBefore[key] ?? []).filter { $0.at >= expectedOn - earlyDays * Time.secondsPerDay }
            let arrived = ((thisMonth[key] ?? []) + early)
                .filter { Double($0.amount.cents) >= arrivalFraction * Double(latest.amount.cents) }
                .min { $0.at < $1.at }
            let status: ExpectedExpense.Status
            if let arrived {
                status = .paid(amount: arrived.amount, on: arrived.at, transactionId: arrived.transactionId)
            } else {
                status = now > expectedOn + graceDays * Time.secondsPerDay ? .late : .upcoming
            }
            let item = ExpectedExpense(key: key, name: (arrived ?? latest).label, expected: latest.amount,
                                       expectedOn: expectedOn, monthsSeen: months, lookbackMonths: lookback.count,
                                       accountName: (arrived ?? latest).accountName,
                                       categoryId: (arrived ?? latest).categoryId, status: status)
            if item.isPaid { paid.append(item) } else { upcoming.append(item) }
        }

        func paidOn(_ e: ExpectedExpense) -> UnixTime {
            if case .paid(_, let on, _) = e.status { return on }
            return e.expectedOn
        }
        upcoming.sort { ($0.expectedOn, $0.key) < ($1.expectedOn, $1.key) }
        paid.sort { (paidOn($0), $0.key) < (paidOn($1), $1.key) }
        return ExpectedMonth(upcoming: upcoming, paid: paid,
                             dismissed: dismissed.sorted { ($0.name, $0.key) < ($1.name, $1.key) },
                             settings: settings, needsMoreHistory: activeMonths.count < 2)
    }

    /// Lower median for even counts, so the result is always an observed value.
    static func medianCents(_ values: [Int64]) -> Int64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2]
    }
}
