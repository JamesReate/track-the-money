import Foundation

// Net-worth rollup + property equity (TECH_DESIGN §9 / PLAN §3). No double
// counting: a property contributes its market value as an asset while its
// linked mortgage/HELOC accounts contribute as liabilities.
//
// TODO(M1.4): compute NetWorthSummary from latest account balances + latest
// property_values; build the over-time series from balance_snapshots.

public struct AccountBalance: Sendable {
    public let accountClass: AccountClass
    public let balance: Money
    public init(accountClass: AccountClass, balance: Money) {
        self.accountClass = accountClass
        self.balance = balance
    }
}

// Inputs for the over-time series (decoupled from storage).
public struct SeriesSnapshot: Sendable {
    public let accountId: String
    public let contribution: AccountClass.Contribution
    public let balanceCents: Int64
    public let balanceDate: UnixTime
    public init(accountId: String, contribution: AccountClass.Contribution, balanceCents: Int64, balanceDate: UnixTime) {
        self.accountId = accountId; self.contribution = contribution
        self.balanceCents = balanceCents; self.balanceDate = balanceDate
    }
}

public struct SeriesPropertyValue: Sendable {
    public let propertyId: String
    public let valueCents: Int64
    public let asOf: UnixTime
    public init(propertyId: String, valueCents: Int64, asOf: UnixTime) {
        self.propertyId = propertyId; self.valueCents = valueCents; self.asOf = asOf
    }
}

public struct NetWorthPoint: Equatable, Sendable {
    public let asOf: UnixTime
    public let netWorth: Money
    public init(asOf: UnixTime, netWorth: Money) { self.asOf = asOf; self.netWorth = netWorth }
}

public enum NetWorth {
    /// Pure rollup over already-loaded balances + property values. Liabilities
    /// are stored as positive magnitudes here.
    public static func summary(accounts: [AccountBalance], propertyValues: [Money], asOf: UnixTime) -> NetWorthSummary {
        func sum(_ cls: AccountClass) -> Money {
            accounts.filter { $0.accountClass == cls }.reduce(Money.zero) { $0 + $1.balance }
        }
        let liquid = sum(.liquid)
        let investments = sum(.investment)
        let secured = sum(.securedDebt)
        let unsecured = sum(.unsecuredDebt)
        let realEstateValue = propertyValues.reduce(Money.zero, +)

        let assets = liquid + investments + realEstateValue
        let liabilities = secured + unsecured
        // NOTE: realEstateEquity here is gross property value; subtracting the
        // SPECIFIC linked mortgage/HELOC balances (per property_debts) happens at
        // the facade level where the links are known. Avoid subtracting all debt.
        return NetWorthSummary(
            assets: assets,
            liabilities: liabilities,
            liquid: liquid,
            investments: investments,
            realEstateEquity: realEstateValue,
            securedDebt: secured,
            unsecuredDebt: unsecured,
            asOf: asOf
        )
    }

    /// Reconstruct net worth at each date where any balance/value changed
    /// (step function: each account/property holds its last known value).
    /// Optional [from, to] window filters the returned points (unix seconds).
    public static func series(snapshots: [SeriesSnapshot],
                              propertyValues: [SeriesPropertyValue],
                              from: UnixTime? = nil,
                              to: UnixTime? = nil) -> [NetWorthPoint] {
        let accountGroups = Dictionary(grouping: snapshots, by: { $0.accountId })
            .mapValues { $0.sorted { $0.balanceDate < $1.balanceDate } }
        let propertyGroups = Dictionary(grouping: propertyValues, by: { $0.propertyId })
            .mapValues { $0.sorted { $0.asOf < $1.asOf } }

        var dates = Set<UnixTime>()
        snapshots.forEach { dates.insert($0.balanceDate) }
        propertyValues.forEach { dates.insert($0.asOf) }

        return dates.sorted().compactMap { date -> NetWorthPoint? in
            if let from, date < from { return nil }
            if let to, date > to { return nil }

            var total: Int64 = 0
            for (_, snaps) in accountGroups {
                guard let latest = snaps.last(where: { $0.balanceDate <= date }) else { continue }
                switch latest.contribution {
                case .asset: total += latest.balanceCents
                case .liability: total -= abs(latest.balanceCents)
                case .ignored: break
                }
            }
            for (_, values) in propertyGroups {
                if let latest = values.last(where: { $0.asOf <= date }) {
                    total += latest.valueCents
                }
            }
            return NetWorthPoint(asOf: date, netWorth: Money(cents: total))
        }
    }
}
