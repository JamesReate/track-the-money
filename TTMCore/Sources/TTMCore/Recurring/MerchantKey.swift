import Foundation

/// A stable grouping key for "the same merchant" across months, from a payee or
/// bank description (docs/plans/EXPECTED_EXPENSES_PLAN.md D2, ADR-0027).
///
/// Stored in `expected_expense_dismissals`, so these rules are part of the data
/// format: changing them orphans saved removals.
public enum MerchantKey {
    /// Card-network and bank prefixes that say how a charge was paid, not who
    /// was paid. Dropped only from the front.
    static let leadingNoise: Set<String> = [
        "POS", "ACH", "DEBIT", "CREDIT", "PURCHASE", "CHECKCARD", "CARD", "RECURRING",
        "ONLINE", "WEB", "PPD", "SQ", "TST", "PREAUTHORIZED", "AUTOPAY", "BILL", "PMT",
    ]
    /// Suffix tokens that don't distinguish merchants.
    static let dropped: Set<String> = ["COM", "NET", "WWW", "HTTPS", "HTTP", "INC", "LLC", "LTD", "CO", "CORP"]
    static let maxTokens = 3

    public static func of(_ text: String) -> String {
        let tokens = text.uppercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { token in !token.contains(where: \.isNumber) && !dropped.contains(token) }
        let meaningful = Array(tokens.drop(while: { leadingNoise.contains($0) }))
        let kept = (meaningful.isEmpty ? tokens : meaningful).prefix(maxTokens)
        return kept.joined(separator: " ")
    }
}
