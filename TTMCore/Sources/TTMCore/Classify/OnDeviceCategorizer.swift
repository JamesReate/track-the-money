import Foundation

// The seam for FREE, on-device AI categorization (Apple Foundation Models, or a
// Create ML / Core ML text classifier). This is a PURE protocol so TTMCore stays
// portable (TECH_DESIGN §13) — the Apple implementation lives in the app layer and
// is injected like SecretStore/Clock, never imported here. It sits as the second
// line of the pipeline (TECH_DESIGN §8): reached only when rules miss, and it
// produces a *suggestion* that is surfaced for confirmation — never auto-applied
// (PLAN §4.2/§4.3). Confirming a suggestion can promote it to a deterministic rule.

/// A category the model may choose from (decoupled from storage, like `TxnView`).
public struct CategoryOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let groupName: String?   // parent group, e.g. "Food" — context for the model
    public init(id: String, name: String, groupName: String? = nil) {
        self.id = id; self.name = name; self.groupName = groupName
    }
}

/// A proposed categorization from a non-deterministic source. Carries confidence
/// and an optional payee to seed a one-tap "create rule".
public struct CategorySuggestion: Sendable, Equatable {
    public let categoryId: String
    public let confidence: Double          // 0...1
    public let suggestedRulePayee: String?
    public let rationale: String?
    public init(categoryId: String, confidence: Double, suggestedRulePayee: String? = nil, rationale: String? = nil) {
        self.categoryId = categoryId; self.confidence = confidence
        self.suggestedRulePayee = suggestedRulePayee; self.rationale = rationale
    }
}

public protocol OnDeviceCategorizer: Sendable {
    /// Whether a model is usable on this device right now (e.g. Apple Intelligence
    /// enabled + supported OS/hardware, or a bundled Core ML model present). Gates
    /// the call so unsupported devices fall back to rules-only at zero cost.
    var isAvailable: Bool { get }

    /// Propose a category for an uncategorized transaction, choosing from `options`.
    /// Returns nil when the model declines or is unavailable.
    func suggest(_ txn: TxnView, options: [CategoryOption]) async -> CategorySuggestion?
}

/// Default free-tier behavior: no on-device model, so the app is rules-only exactly
/// as today. Apps opt in by injecting a real implementation into `LocalCore`.
public struct NoOpOnDeviceCategorizer: OnDeviceCategorizer {
    public init() {}
    public var isAvailable: Bool { false }
    public func suggest(_ txn: TxnView, options: [CategoryOption]) async -> CategorySuggestion? { nil }
}
