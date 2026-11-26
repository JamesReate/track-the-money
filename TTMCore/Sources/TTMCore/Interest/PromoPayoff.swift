import Foundation

// Credit-card promotional rates and whether cash on hand can clear them before
// they end (docs/plans/PROMO_APR_PLAN.md, ADR-0026). Pure math: callers pass
// `now`, balances as positive magnitudes (ADR-0012) and liquid cash.

/// A promotional APR that applies through the end of `endsOn`'s day.
public struct PromoRate: Equatable, Sendable {
    public let aprBps: Int
    /// Start of the promo's last day (the app sends local start-of-day).
    public let endsOn: UnixTime
    public init(aprBps: Int, endsOn: UnixTime) { self.aprBps = aprBps; self.endsOn = endsOn }

    /// The first moment the promo no longer applies.
    public var expiresAt: UnixTime { endsOn + Time.secondsPerDay }
    public func isActive(at now: UnixTime) -> Bool { now < expiresAt }
}

/// One promo card's payoff picture.
public struct PromoPayoff: Equatable, Sendable, Identifiable {
    public let accountId: String
    public let accountName: String
    /// What's owed now (magnitude). The promo is assumed to cover all of it.
    public let balance: Money
    public let promo: PromoRate
    /// The card's regular APR, which applies once the promo ends (nil if unset).
    public let regularAprBps: Int?
    /// Whole days until the promo ends, counting today.
    public let daysLeft: Int
    /// Monthly payments left before it ends (at least 1).
    public let monthsLeft: Int
    /// Equal monthly payment that clears the balance by the end date.
    public let monthlyToClear: Money
    /// Rough monthly interest once the promo ends if nothing is paid
    /// (balance × regular APR ÷ 12); nil without a regular rate.
    public let interestPerMonthAfter: Money?
    /// This balance plus every promo balance ending on or before it: what cash
    /// must cover if it's spent on the earliest deadlines first.
    public let dueByThen: Money
    /// How much of `dueByThen` liquid cash can't cover (zero when covered).
    public let shortfall: Money

    public var id: String { accountId }
    public var covered: Bool { shortfall == .zero }

    public init(accountId: String, accountName: String, balance: Money, promo: PromoRate, regularAprBps: Int?,
                daysLeft: Int, monthsLeft: Int, monthlyToClear: Money, interestPerMonthAfter: Money?,
                dueByThen: Money, shortfall: Money) {
        self.accountId = accountId; self.accountName = accountName; self.balance = balance; self.promo = promo
        self.regularAprBps = regularAprBps; self.daysLeft = daysLeft; self.monthsLeft = monthsLeft
        self.monthlyToClear = monthlyToClear; self.interestPerMonthAfter = interestPerMonthAfter
        self.dueByThen = dueByThen; self.shortfall = shortfall
    }
}

/// Every active promo against the cash that could pay it off.
public struct PromoOutlook: Equatable, Sendable {
    /// Liquid cash (checking, savings…) that counts — never below zero.
    public let liquid: Money
    /// Active promos with a balance, earliest end first.
    public let payoffs: [PromoPayoff]
    public var totalDue: Money { payoffs.reduce(.zero) { $0 + $1.balance } }
    /// Promo balances cash can't cover at all.
    public var shortfall: Money { payoffs.last?.shortfall ?? .zero }

    public init(liquid: Money, payoffs: [PromoPayoff]) { self.liquid = liquid; self.payoffs = payoffs }
}

public enum PromoMath {
    public struct Card: Sendable {
        public let accountId: String
        public let name: String
        public let balanceCents: Int64          // magnitude
        public let promo: PromoRate
        public let regularAprBps: Int?
        public init(accountId: String, name: String, balanceCents: Int64, promo: PromoRate, regularAprBps: Int?) {
            self.accountId = accountId; self.name = name; self.balanceCents = balanceCents
            self.promo = promo; self.regularAprBps = regularAprBps
        }
    }

    /// Monthly payments left: one per started month (365/12 days) after today,
    /// at least one. A promo ending a year from today leaves 12.
    static func monthsLeft(daysAfterToday: Int) -> Int {
        max(1, (daysAfterToday * 12 + 364) / 365)
    }

    public static func outlook(cards: [Card], liquidCents: Int64, now: UnixTime) -> PromoOutlook {
        let liquid = max(0, liquidCents)
        let live = cards
            .filter { $0.promo.isActive(at: now) && $0.balanceCents > 0 }
            .sorted { ($0.promo.endsOn, $0.name) < ($1.promo.endsOn, $1.name) }

        var due: Int64 = 0
        let payoffs = live.map { card -> PromoPayoff in
            due += card.balanceCents
            let secondsLeft = card.promo.expiresAt - now
            let days = Int((secondsLeft + Time.secondsPerDay - 1) / Time.secondsPerDay)
            let months = monthsLeft(daysAfterToday: days - 1)
            let monthly = (card.balanceCents + Int64(months) - 1) / Int64(months)          // round up
            let interest = card.regularAprBps.map { (card.balanceCents * Int64($0) + 60_000) / 120_000 }
            return PromoPayoff(
                accountId: card.accountId, accountName: card.name, balance: Money(cents: card.balanceCents),
                promo: card.promo, regularAprBps: card.regularAprBps, daysLeft: days, monthsLeft: months,
                monthlyToClear: Money(cents: monthly), interestPerMonthAfter: interest.map { Money(cents: $0) },
                dueByThen: Money(cents: due), shortfall: Money(cents: max(0, due - liquid)))
        }
        return PromoOutlook(liquid: Money(cents: liquid), payoffs: payoffs)
    }
}
