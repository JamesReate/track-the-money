import Foundation

// On-device SimpleFIN sync (TECH_DESIGN §6). Runs in BOTH tiers; the server
// never calls SimpleFIN. Weekly default cadence + manual "Sync now". Idempotent
// upsert on (account_id, sfin_txn_id); balance snapshots on (account_id,
// balance_date); pending→posted reconciliation; per-connection failure isolation.
//
// TODO(M1.3): implement against Database + SimpleFINClient + Clock, returning a
// SyncOutcome. Smart-default account class on first sight only; run the
// categorization pipeline on new transactions.

public struct SyncEngine: Sendable {
    private let db: Database
    private let client: SimpleFINClient
    private let secrets: SecretStore
    private let clock: Clock

    public init(db: Database, client: SimpleFINClient, secrets: SecretStore, clock: Clock) {
        self.db = db
        self.client = client
        self.secrets = secrets
        self.clock = clock
    }

    /// Default sync window: re-pull recent transactions with overlap so late
    /// posts/edits are caught (TECH_DESIGN §6).
    public static let overlap: UnixTime = 7 * Time.secondsPerDay
}
