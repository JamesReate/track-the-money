import Foundation

// Seed categories shipped on first launch (PLAN.md §4.1). Idempotent: only seeds
// when the categories table is empty.
public enum DefaultData {
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
        guard try store.categoryCount() == 0 else { return }
        for (index, seed) in categories.enumerated() {
            try store.saveCategory(CategoryRecord(
                id: seed.id, name: seed.name, parentId: nil, kind: seed.kind,
                color: nil, sort: index, createdAt: now
            ))
        }
    }
}
