import Foundation

// Interest & debt-cost tracking (PLAN §5). Interest charges are categorized via
// rules (e.g. description contains "INTEREST CHARGE" / "FINANCE CHARGE") + AI.
// Mortgage/loan payments split into principal/interest/escrow (payment_splits);
// the interest portion feeds interest rollups by account and period.
//
// TODO(M1.7): implement rollups (interest paid by account / month / YTD) over
// categorized interest txns + split interest portions.

public enum Interest {
    /// Seed patterns for the default interest-detection rules.
    public static let defaultInterestPatterns = [
        "INTEREST CHARGE", "FINANCE CHARGE", "INTEREST CHARGED", "PURCHASE INTEREST",
    ]
}
