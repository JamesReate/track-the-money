import Foundation
import TTMCore

/// A lightweight, always-available on-device categorizer: a curated
/// merchant-keyword → category map. Deterministic, offline, works on every device
/// with no model download. It's the free baseline behind the `OnDeviceCategorizer`
/// seam; Apple's Foundation Models LLM is the smarter upgrade on capable devices
/// (see `FoundationModelsCategorizer`), and paid Claude is the cloud option.
///
/// It only ever suggests a category that's actually in `options` (the user's own
/// assignable leaves), so it adapts if categories are renamed/removed.
struct HeuristicOnDeviceCategorizer: OnDeviceCategorizer {
    var isAvailable: Bool { true }

    /// (keyword, seed category id). First containment match wins, so order
    /// specific → generic. Keys are matched case-insensitively.
    private static let rules: [(String, String)] = [
        // streaming
        ("NETFLIX", "streaming"), ("SPOTIFY", "streaming"), ("HULU", "streaming"),
        ("DISNEY", "streaming"), ("HBO", "streaming"), ("YOUTUBE", "streaming"), ("PARAMOUNT", "streaming"),
        // dining
        ("STARBUCKS", "dining"), ("BLUE BOTTLE", "dining"), ("COFFEE", "dining"), ("DUNKIN", "dining"),
        ("RESTAURANT", "dining"), ("CAFE", "dining"), ("CHIPOTLE", "dining"), ("MCDONALD", "dining"),
        ("DOORDASH", "dining"), ("UBER EATS", "dining"), ("GRUBHUB", "dining"), ("PIZZA", "dining"),
        // groceries
        ("WHOLE FOODS", "groceries"), ("TRADER JOE", "groceries"), ("SAFEWAY", "groceries"),
        ("KROGER", "groceries"), ("ALDI", "groceries"), ("COSTCO", "groceries"), ("GROCERY", "groceries"),
        // auto / fuel
        ("SHELL", "auto"), ("CHEVRON", "auto"), ("EXXON", "auto"), ("76 ", "auto"),
        ("GAS", "auto"), ("FUEL", "auto"), ("AUTOZONE", "auto"), ("PARKING", "auto"),
        // utilities
        ("PG&E", "utilities"), ("UTILITY", "utilities"), ("ELECTRIC", "utilities"), ("COMCAST", "utilities"),
        ("XFINITY", "utilities"), ("VERIZON", "utilities"), ("AT&T", "utilities"), ("T-MOBILE", "utilities"),
        // pets
        ("CHEWY", "pets"), ("PETCO", "pets"), ("PETSMART", "pets"), ("VET", "pets"), ("GROOMER", "pets"),
        // home
        ("HOME DEPOT", "home"), ("LOWE", "home"), ("IKEA", "home"), ("WAYFAIR", "home"), ("AMAZON", "home"),
        // health
        ("CVS", "health"), ("WALGREENS", "health"), ("PHARMACY", "health"), ("DENTAL", "health"),
        ("CLINIC", "health"), ("FITNESS", "health"), ("GYM", "health"),
        // going out
        ("TICKETMASTER", "going-out"), ("LIVE NATION", "going-out"), ("CINEMA", "going-out"),
        ("AMC ", "going-out"), ("THEATER", "going-out"),
    ]

    func suggest(_ txn: TxnView, options: [CategoryOption]) async -> CategorySuggestion? {
        // Test affordance: simulate real on-device-model latency so the loading
        // indicator is observable (the heuristic is otherwise instant).
        if ProcessInfo.processInfo.arguments.contains("-slowAI") {
            try? await Task.sleep(for: .seconds(3))
        }
        let haystack = (txn.description + " " + (txn.payee ?? "")).uppercased()
        let available = Set(options.map { $0.id })
        for (needle, categoryId) in Self.rules where available.contains(categoryId) {
            if haystack.contains(needle.uppercased()) {
                return CategorySuggestion(categoryId: categoryId, confidence: 0.8,
                                          suggestedRulePayee: txn.payee?.isEmpty == false ? txn.payee : txn.description,
                                          rationale: "Matched “\(needle.trimmingCharacters(in: .whitespaces))”")
            }
        }
        return nil
    }
}
