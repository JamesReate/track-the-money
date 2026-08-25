import Foundation

// Seed categories shipped on first launch (PLAN.md §4.1, CATEGORIZATION_PLAN.md §8).
//
// The category tree is reconciled by `ensureCategories`, which is idempotent and
// safe to run on every launch: it ADDS any missing canonical category (so existing
// installs gain the new groups and the Entertainment leaves) and fills the
// canonical parent/color/sort onto *pristine* seeds (those a user has never
// regrouped or recolored). It never overwrites a user's edits — that "pristine"
// guard is what lets it double as the migration for already-seeded installs
// without a one-shot DDL step (parent_id/color already exist on the table).
public enum DefaultData {
    public static let interestCategoryId = "interest"

    public struct Seed {
        let id: String; let name: String; let kind: String
        let parentId: String?; let color: String?
        init(_ id: String, _ name: String, _ kind: String, parent: String? = nil, color: String? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.parentId = parent; self.color = color
        }
    }

    /// Canonical tree, in display/sort order (a group immediately precedes its
    /// children). Array index becomes `sort`. Groups are headers — they carry a
    /// color for their dot but transactions attach only to leaves (those with no
    /// children). See CATEGORIZATION_PLAN.md §1.
    public static let seeds: [Seed] = [
        // Food
        Seed("grp-food", "Food", "expense", color: "#4C6B5B"),
        Seed("groceries", "Groceries", "expense", parent: "grp-food", color: "#5E8C6A"),
        Seed("dining", "Dining", "expense", parent: "grp-food", color: "#7A6E9A"),
        // Home
        Seed("grp-home", "Home", "expense", color: "#5B6B8C"),
        Seed("home", "Home", "expense", parent: "grp-home", color: "#6E8CA0"),
        Seed("utilities", "Utilities", "expense", parent: "grp-home", color: "#4F7C76"),
        // Family
        Seed("grp-family", "Family", "expense", color: "#C08A3E"),
        Seed("kids", "Kids", "expense", parent: "grp-family", color: "#8C7A4E"),
        Seed("pets", "Pets", "expense", parent: "grp-family", color: "#8C5A6E"),
        // Entertainment (new)
        Seed("grp-entertainment", "Entertainment", "expense", color: "#9A5A4E"),
        Seed("streaming", "Streaming", "expense", parent: "grp-entertainment", color: "#A0785A"),
        Seed("concerts", "Concerts", "expense", parent: "grp-entertainment", color: "#B0734E"),
        Seed("going-out", "Going Out", "expense", parent: "grp-entertainment", color: "#586E5A"),
        // Standalone leaves
        Seed("auto", "Auto", "expense", color: "#9A7B9A"),
        Seed("health", "Health", "expense", color: "#4C6B5B"),
        // System (flat, not groupable)
        Seed("income", "Income", "income", color: "#1E4D3A"),
        Seed("transfer", "Transfer", "transfer", color: "#6A746E"),
        Seed("interest", "Interest", "interest", color: "#B0533C"),
        Seed("uncategorized", "Uncategorized", "system", color: "#B9C0BA"),
    ]

    /// Kinds that are system categories: flat, undeletable, not groupable, and
    /// excluded from being a parent. (Expense leaves/groups are the editable set.)
    public static let systemKinds: Set<String> = ["income", "transfer", "interest", "system"]

    public static func seedIfEmpty(_ store: Store, now: UnixTime) throws {
        try ensureCategories(store, now: now)
        try seedRulesIfEmpty(store, now: now)
    }

    /// Reconcile the category tree toward `seeds`. Idempotent; preserves user edits.
    static func ensureCategories(_ store: Store, now: UnixTime) throws {
        let existing = try store.allCategories()
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, seed) in seeds.enumerated() {
            if let current = byId[seed.id] {
                // Only reorganize a still-pristine seed (never regrouped or
                // recolored). Once a user touches it, we leave it alone forever.
                let pristine = current.parentId == nil && current.color == nil
                let canonicalHasShape = seed.parentId != nil || seed.color != nil
                if pristine && canonicalHasShape {
                    var updated = current
                    updated.parentId = seed.parentId
                    updated.color = seed.color
                    updated.sort = index
                    try store.saveCategory(updated)
                }
            } else {
                try store.saveCategory(CategoryRecord(
                    id: seed.id, name: seed.name, parentId: seed.parentId, kind: seed.kind,
                    color: seed.color, sort: index, createdAt: now
                ))
            }
        }
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
