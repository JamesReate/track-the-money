import Foundation

/// Money as integer minor units (cents). NEVER use Double for money.
/// SimpleFIN sends amounts as decimal strings ("-42.07"); parse via Decimal.
public struct Money: Equatable, Hashable, Codable, Comparable, Sendable {
    public let cents: Int64

    public init(cents: Int64) { self.cents = cents }

    public static let zero = Money(cents: 0)

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }
    public static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    public static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    public static prefix func - (m: Money) -> Money { Money(cents: -m.cents) }

    /// Parse a SimpleFIN decimal string into cents, exactly (no float).
    /// `scale` is the number of minor-unit digits (2 for USD).
    public init?(decimalString string: String, scale: Int = 2) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard var value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        // value * 10^scale, then round to an integer number of minor units.
        value *= Decimal(sign: .plus, exponent: scale, significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .bankers)
        self.cents = NSDecimalNumber(decimal: rounded).int64Value
    }

    /// Localized currency string for display (Decimal-based; no float).
    public func formatted(currencyCode: String = "USD", scale: Int = 2) -> String {
        let amount = Decimal(cents) / Decimal(sign: .plus, exponent: scale, significand: 1)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(cents)"
    }
}
