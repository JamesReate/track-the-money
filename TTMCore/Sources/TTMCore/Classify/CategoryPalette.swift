import Foundation

// The category color palette (CATEGORIZATION_PLAN.md §3). A curated set of muted,
// paper-friendly tones that sit alongside "The Statement" brand anchors
// (evergreen=assets, clay=debts) without competing with them. Lives in TTMCore so
// both the seed data and the on-create auto-assignment draw from one source; the
// app renders the stored hex string back into a Color.
public enum CategoryPalette {
    /// `#RRGGBB` hex strings. Order is significant: auto-assignment and tie-breaks
    /// walk the list in order, so it must stay stable across releases.
    public static let hexes: [String] = [
        "#4C6B5B", // sage
        "#5B6B8C", // dusty blue
        "#C08A3E", // ochre
        "#9A5A4E", // brick
        "#7A6E9A", // muted violet
        "#4F7C76", // teal
        "#8C7A4E", // olive brass
        "#8C5A6E", // plum
        "#5E8C6A", // fern
        "#A0785A", // taupe
        "#6E8CA0", // steel
        "#B0734E", // amber brown
        "#586E5A", // moss
        "#9A7B9A", // lilac
    ]

    /// Fixed, semantic colors for the non-expense system categories so they read
    /// meaningfully wherever a color dot appears.
    public static let systemColors: [String: String] = [
        "income": "#1E4D3A",        // evergreen — money in
        "transfer": "#6A746E",      // slate — neutral, excluded from spend
        "interest": "#B0533C",      // clay — a cost
        "uncategorized": "#B9C0BA", // faint — a to-do, not a resting state
    ]

    /// Deterministically pick the least-used palette hue given the colors already
    /// in use, breaking ties by palette order. No RNG — reproducible and
    /// test-stable (and safe for the future Rust port's golden vectors).
    public static func nextColor(usedColors: [String]) -> String {
        let used = usedColors.map { $0.uppercased() }
        var counts = [String: Int]()
        for hex in hexes { counts[hex.uppercased()] = 0 }
        for c in used where counts[c] != nil { counts[c, default: 0] += 1 }
        return hexes.min { a, b in
            let ca = counts[a.uppercased()] ?? 0, cb = counts[b.uppercased()] ?? 0
            if ca != cb { return ca < cb }
            return (hexes.firstIndex(of: a) ?? 0) < (hexes.firstIndex(of: b) ?? 0)
        } ?? hexes[0]
    }
}
