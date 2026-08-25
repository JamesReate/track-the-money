import Foundation
import TTMCore

#if canImport(FoundationModels)
import FoundationModels

/// The smarter on-device option: Apple's ~3B on-device LLM (Foundation Models),
/// behind the same `OnDeviceCategorizer` seam. Uses guided generation (`@Generable`)
/// so the model is constrained to emit a valid category id + confidence. Available
/// only on Apple-Intelligence-capable devices running iOS 26 / macOS 26; callers
/// fall back to `HeuristicOnDeviceCategorizer` otherwise. Nothing leaves the device.
@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsCategorizer: OnDeviceCategorizer {
    @Generable
    struct Pick {
        @Guide(description: "the exact id of the single best-matching category from the list")
        let categoryId: String
        @Guide(description: "confidence from 0 to 1")
        let confidence: Double
    }

    static var isSupported: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    var isAvailable: Bool { Self.isSupported }

    func suggest(_ txn: TxnView, options: [CategoryOption]) async -> CategorySuggestion? {
        guard !options.isEmpty else { return nil }
        let list = options.map { opt in
            "\(opt.id): \(opt.groupName.map { "\($0) › " } ?? "")\(opt.name)"
        }.joined(separator: "\n")
        let prompt = """
        Pick the single best category for this bank transaction. Use only an id from the list.
        Transaction: \(txn.description)\(txn.payee.map { " (payee: \($0))" } ?? "")
        Amount (cents, negative = spend): \(txn.amountCents)
        Categories (id: name):
        \(list)
        """
        do {
            let session = LanguageModelSession()
            let pick = try await session.respond(to: prompt, generating: Pick.self).content
            guard options.contains(where: { $0.id == pick.categoryId }) else { return nil }
            return CategorySuggestion(categoryId: pick.categoryId,
                                      confidence: min(max(pick.confidence, 0), 1),
                                      suggestedRulePayee: txn.payee?.isEmpty == false ? txn.payee : txn.description,
                                      rationale: "On-device model")
        } catch {
            return nil
        }
    }
}
#endif
