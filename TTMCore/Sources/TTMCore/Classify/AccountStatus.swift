import Foundation

/// Whether an account counts and whether it syncs — independent of its
/// `AccountClass` (what kind of account it is). ADR-0025.
public enum AccountStatus: String, Codable, CaseIterable, Sendable {
    /// Syncs and counts everywhere. The default.
    case active
    /// Keeps syncing but counts nowhere: left out of net worth, the charts,
    /// spending, interest and property equity, and its transactions are hidden
    /// from every list, search, count and transfer match (still stored).
    case excluded
    /// Stops syncing and holds its last balance, which still counts. Resuming
    /// fetches back to where it left off. Only synced accounts can pause.
    case paused

    /// Counts toward net worth, charts, spending and interest.
    public var counts: Bool { self != .excluded }
}
