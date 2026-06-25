import Foundation

// Seed categories shipped on first launch (PLAN.md §4.1). Idempotent: only seeds
// when the categories table is empty.
public enum DefaultData {
    public static let interestCategoryId = "interest"

    public struct Seed { let id: String; let name: String; let kind: String }

    public static let categories: [Seed] = [
        Seed(id: "groceries", name: "Groceries", kind: "expense"),
        Seed(id: "dining", name: "Dining", kind: "expense"),
        Seed(id: "home", name: "Home", kind: "expense"),
        Seed(id: "kids", name: "Kids", kind: "expense"),
        Seed(id: "pets", name: "Pets", kind: "expense"),
        Seed(id: "auto", name: "Auto", kind: "expense"),
        Seed(id: "utilities", name: "Utilities", kind: "expense"),
        Seed(id: "health", name: "Health", kind: "expense"),
        Seed(id: "income", name: "Income", kind: "income"),
        Seed(id: "transfer", name: "Transfer", kind: "transfer"),
        Seed(id: "interest", name: "Interest", kind: "interest"),
        Seed(id: "uncategorized", name: "Uncategorized", kind: "system"),
    ]

    public static func seedIfEmpty(_ store: Store, now: UnixTime) throws {
        if try store.categoryCount() == 0 {
            for (index, seed) in categories.enumerated() {
                try store.saveCategory(CategoryRecord(
                    id: seed.id, name: seed.name, parentId: nil, kind: seed.kind,
                    color: nil, sort: index, createdAt: now
                ))
            }
        }
        try seedRulesIfEmpty(store, now: now)
    }

    /// Default interest-detection rule (description contains any interest phrase
    /// → Interest category). Seeded only when no rules exist.
    static func seedRulesIfEmpty(_ store: Store, now: UnixTime) throws {
        guard try store.ruleCount() == 0 else { return }
        let condition = Condition(op: .or, clauses: Interest.defaultInterestPatterns.map {
            Clause(field: .description, match: .contains, value: $0)
        })
        let json = (try? JSONEncoder().encode(condition)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try store.saveRuleRecord(RuleRecord(
            id: "rule-interest", name: "Interest charges", categoryId: interestCategoryId,
            priority: 50, enabled: true, conditions: json, createdAt: now, updatedAt: now
        ))
    }
}
