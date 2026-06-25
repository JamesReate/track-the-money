import Foundation

// Deterministic categorization rules (TECH_DESIGN §7). Pure logic, fully unit
// tested — first match wins by priority, and the matched rule id is the
// inspectable "why" trail recorded on each transaction.

public enum MatchField: String, Codable, Sendable {
    case description, payee, memo, accountId, amountCents, currency
}

public enum MatchOp: String, Codable, Sendable {
    case contains, eq, regex, lt, lte, gt, gte, between
}

/// One leaf condition. Numeric ops parse `value`/`value2` as Int64 (cents).
public struct Clause: Codable, Equatable, Sendable {
    public let field: MatchField
    public let match: MatchOp
    public let value: String
    public let value2: String?   // upper bound for `between`
    public let ci: Bool?         // case-insensitive (string ops); default true

    public init(field: MatchField, match: MatchOp, value: String, value2: String? = nil, ci: Bool? = nil) {
        self.field = field; self.match = match; self.value = value; self.value2 = value2; self.ci = ci
    }
}

/// A single level of clauses joined by AND/OR. (Nested trees deferred; see
/// TECH_DESIGN §7 — the JSON shape is `{ op, clauses }`.)
public struct Condition: Codable, Equatable, Sendable {
    public enum LogicOp: String, Codable, Sendable { case and, or }
    public let op: LogicOp
    public let clauses: [Clause]
    public init(op: LogicOp, clauses: [Clause]) { self.op = op; self.clauses = clauses }
}

public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let categoryId: String
    public let priority: Int        // lower = evaluated first
    public let enabled: Bool
    public let condition: Condition

    public init(id: String, name: String, categoryId: String, priority: Int, enabled: Bool, condition: Condition) {
        self.id = id; self.name = name; self.categoryId = categoryId
        self.priority = priority; self.enabled = enabled; self.condition = condition
    }
}

/// The subset of a transaction a rule evaluates against (decoupled from storage).
public struct TxnView: Sendable {
    public let description: String
    public let payee: String?
    public let memo: String?
    public let accountId: String
    public let amountCents: Int64
    public let currency: String

    public init(description: String, payee: String?, memo: String?, accountId: String, amountCents: Int64, currency: String) {
        self.description = description; self.payee = payee; self.memo = memo
        self.accountId = accountId; self.amountCents = amountCents; self.currency = currency
    }
}

public enum RulesEngine {
    /// First enabled rule (by ascending priority) whose condition matches.
    public static func firstMatch(_ txn: TxnView, rules: [Rule]) -> Rule? {
        rules.filter { $0.enabled }
            .sorted { $0.priority < $1.priority }
            .first { matches(txn, $0.condition) }
    }

    public static func matches(_ txn: TxnView, _ condition: Condition) -> Bool {
        let results = condition.clauses.map { evaluate($0, txn) }
        switch condition.op {
        case .and: return results.allSatisfy { $0 }
        case .or:  return results.contains(true)
        }
    }

    static func evaluate(_ clause: Clause, _ txn: TxnView) -> Bool {
        switch clause.field {
        case .description: return evalString(txn.description, clause)
        case .payee:       return evalString(txn.payee ?? "", clause)
        case .memo:        return evalString(txn.memo ?? "", clause)
        case .currency:    return evalString(txn.currency, clause)
        case .accountId:   return clause.match == .eq && txn.accountId == clause.value
        case .amountCents: return evalNumber(txn.amountCents, clause)
        }
    }

    private static func evalString(_ raw: String, _ clause: Clause) -> Bool {
        let ci = clause.ci ?? true
        let haystack = ci ? raw.lowercased() : raw
        let needle = ci ? clause.value.lowercased() : clause.value
        switch clause.match {
        case .contains: return haystack.contains(needle)
        case .eq:       return haystack == needle
        case .regex:
            let options: NSRegularExpression.Options = ci ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: clause.value, options: options) else { return false }
            let range = NSRange(raw.startIndex..., in: raw)
            return re.firstMatch(in: raw, options: [], range: range) != nil
        default: return false   // numeric ops don't apply to strings
        }
    }

    private static func evalNumber(_ amount: Int64, _ clause: Clause) -> Bool {
        guard let v = Int64(clause.value) else { return false }
        switch clause.match {
        case .lt:  return amount < v
        case .lte: return amount <= v
        case .gt:  return amount > v
        case .gte: return amount >= v
        case .eq:  return amount == v
        case .between:
            guard let v2 = clause.value2.flatMap(Int64.init) else { return false }
            return amount >= min(v, v2) && amount <= max(v, v2)
        default: return false
        }
    }
}
