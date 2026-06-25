import Foundation

// Deterministic categorization pipeline (TECH_DESIGN §8). Free tier stops at
// rules; AI fallback (paid) is wired in separately and only for uncategorized
// transactions. This type owns the rules half.
public struct Categorizer: Sendable {
    private let store: Store
    private let clock: Clock

    public init(store: Store, clock: Clock) {
        self.store = store
        self.clock = clock
    }

    /// Decode persisted rule rows into domain rules (skips malformed conditions).
    public func loadRules() throws -> [Rule] {
        let decoder = JSONDecoder()
        return try store.allRuleRecords().compactMap { rec in
            guard let data = rec.conditions.data(using: .utf8),
                  let condition = try? decoder.decode(Condition.self, from: data) else {
                return nil
            }
            return Rule(id: rec.id, name: rec.name, categoryId: rec.categoryId,
                        priority: rec.priority, enabled: rec.enabled, condition: condition)
        }
    }

    /// First matching rule for a freshly-synced transaction, if any.
    public func categorize(_ txn: TxnView, rules: [Rule]) -> (categoryId: String, source: String)? {
        guard let rule = RulesEngine.firstMatch(txn, rules: rules) else { return nil }
        return (rule.categoryId, "rule:\(rule.id)")
    }

    /// Re-evaluate stored transactions against the rule set.
    /// - forwardOnly: no-op here (new txns are categorized at sync time).
    /// - backfill: only uncategorized transactions.
    /// - rerunAll: every non-manual transaction.
    public func reapply(mode: RuleApplyMode) throws {
        guard mode != .forwardOnly else { return }
        let rules = try loadRules()
        let rows = try store.transactionsForMatching(onlyUncategorized: mode == .backfill)
        let now = clock.now()
        for row in rows {
            let view = TxnView(description: row.description, payee: row.payee, memo: row.memo,
                               accountId: row.accountId, amountCents: row.amountCents, currency: row.currency)
            if let hit = categorize(view, rules: rules) {
                try store.setTransactionCategory(id: row.id, categoryId: hit.categoryId, source: hit.source, updatedAt: now)
            }
        }
    }
}
