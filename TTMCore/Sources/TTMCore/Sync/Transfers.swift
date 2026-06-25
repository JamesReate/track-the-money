import Foundation

// Transfer auto-detection (TECH_DESIGN §8). Pairs opposite-sign, equal-magnitude
// transactions across two different accounts within a small date window, marks
// both as transfers (shared group id), and assigns the Transfer category so they
// are excluded from spend totals. Conservative: only touches uncategorized,
// not-yet-transfer transactions.
public enum Transfers {
    public static let defaultWindow: UnixTime = 3 * Time.secondsPerDay

    @discardableResult
    public static func detect(store: Store, now: UnixTime,
                              transferCategoryId: String,
                              window: UnixTime = defaultWindow) throws -> Int {
        let candidates = try store.transferCandidates()
        var used = Set<String>()
        var pairs = 0

        for (i, a) in candidates.enumerated() {
            if used.contains(a.id) { continue }
            guard let aPosted = a.postedAt else { continue }
            for b in candidates[(i + 1)...] {
                if used.contains(b.id) { continue }
                guard let bPosted = b.postedAt else { continue }
                guard a.accountId != b.accountId,
                      a.amountCents == -b.amountCents,
                      abs(aPosted - bPosted) <= window else { continue }

                try store.markTransferPair(a.id, b.id, groupId: UUID().uuidString,
                                           categoryId: transferCategoryId, now: now)
                used.insert(a.id); used.insert(b.id)
                pairs += 1
                break
            }
        }
        return pairs
    }
}
