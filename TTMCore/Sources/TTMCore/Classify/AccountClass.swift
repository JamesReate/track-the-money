import Foundation

/// How an account rolls up into net worth (PLAN.md §3.1).
public enum AccountClass: String, Codable, CaseIterable, Sendable {
    case liquid          // + asset: checking, savings, money market
    case investment      // + asset: brokerage, retirement, HSA
    case securedDebt     // - liability: mortgage, auto loan, HELOC
    case unsecuredDebt   // - liability: credit cards, personal/student loans
    case realEstate      // + asset (manual value); see Property
    case income          // tracked, not a net-worth balance
    case excluded        // ignored
    case unclassified    // default until the user (or guesser) assigns

    /// Sign of this class's balance in the net-worth rollup.
    public enum Contribution: Sendable { case asset, liability, ignored }
    public var contribution: Contribution {
        switch self {
        case .liquid, .investment, .realEstate: return .asset
        case .securedDebt, .unsecuredDebt: return .liability
        case .income, .excluded, .unclassified: return .ignored
        }
    }
}

public enum AccountClassifier {
    /// Smart default guess from the account name, applied ONLY on first sight
    /// (never overrides a user's choice). Deliberately conservative.
    public static func guess(name: String) -> AccountClass {
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { n.contains($0) } }

        if has(["visa", "mastercard", "amex", "credit card", "card ending", "loan", "student"]) {
            return .unsecuredDebt
        }
        if has(["mortgage", "heloc", "home equity", "auto loan"]) { return .securedDebt }
        if has(["401k", "ira", "roth", "brokerage", "hsa", "invest", "vanguard", "fidelity"]) {
            return .investment
        }
        if has(["checking", "savings", "money market", "cash", "checkings"]) { return .liquid }
        return .unclassified
    }
}
