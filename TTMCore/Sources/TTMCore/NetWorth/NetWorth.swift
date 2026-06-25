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
}
