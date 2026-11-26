import Foundation

/// How an account rolls up into net worth (PLAN.md §3.1). Whether it counts at
/// all is its `AccountStatus` — "excluded" used to be a class here and became a
/// status in migration v5 (ADR-0025), so excluding keeps the account's kind.
public enum AccountClass: String, Codable, CaseIterable, Sendable {
    case liquid          // + asset: checking, savings, money market
    case investment      // + asset: brokerage, retirement, HSA
    case securedDebt     // - liability: mortgage, auto loan, HELOC
    case creditCard      // - liability: a credit card (rolls up as unsecured debt)
    case unsecuredDebt   // - liability: personal/student loans, other unsecured
    case realEstate      // + asset (manual value); see Property
    case income          // tracked, not a net-worth balance
    case unclassified    // default until the user (or guesser) assigns

    /// Sign of this class's balance in the net-worth rollup.
    public enum Contribution: Sendable { case asset, liability, ignored }
    public var contribution: Contribution {
        switch self {
        case .liquid, .investment, .realEstate: return .asset
        case .securedDebt, .creditCard, .unsecuredDebt: return .liability
        case .income, .unclassified: return .ignored
        }
    }

    /// Debt classes carry an interest rate (APR) and appear on Debt & Interest.
    public var isDebt: Bool { contribution == .liability }
}

public enum AccountClassifier {
    /// Smart default guess from the account name, applied ONLY on first sight
    /// (never overrides a user's choice). Deliberately conservative.
    public static func guess(name: String) -> AccountClass {
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { n.contains($0) } }

        // Secured debt first: "auto loan" must not fall through to unsecured.
        if has(["mortgage", "heloc", "home equity", "auto loan"]) { return .securedDebt }
        if has(["visa", "mastercard", "amex", "credit card", "card ending"]) {
            return .creditCard
        }
        if has(["loan", "student"]) { return .unsecuredDebt }
        if has(["401k", "ira", "roth", "brokerage", "hsa", "invest", "vanguard", "fidelity"]) {
            return .investment
        }
        if has(["checking", "savings", "money market", "cash", "checkings"]) { return .liquid }
        return .unclassified
    }
}
