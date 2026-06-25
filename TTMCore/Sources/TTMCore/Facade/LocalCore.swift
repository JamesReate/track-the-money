import Foundation

/// The free, on-device `CoreFacade` implementation: SQLite + on-device SimpleFIN
/// sync + deterministic rules. No backend. The SwiftUI app talks only to this.
public final class LocalCore: CoreFacade {
    private let store: Store
    private let secrets: SecretStore
    private let network: NetworkClient
    private let clock: Clock
    private let client: SimpleFINClient
    private let engine: SyncEngine
    private let categorizer: Categorizer

    public init(dbPath: String, secrets: SecretStore, network: NetworkClient, clock: Clock = SystemClock()) throws {
        let database = try Database(path: dbPath)
        self.store = Store(database)
        self.secrets = secrets
        self.network = network
        self.clock = clock
        self.client = LiveSimpleFINClient(net: network)
        self.engine = SyncEngine(store: store, client: client, secrets: secrets, clock: clock)
        self.categorizer = Categorizer(store: store, clock: clock)
        try DefaultData.seedIfEmpty(store, now: clock.now())
    }

    // MARK: Connections / sync

    public func claimSetupToken(_ token: String) async throws {
        // SimpleFIN: base64-decode the setup token to a claim URL, POST to it,
        // receive the long-lived Access URL. Store it in Keychain (device-only).
        guard let data = Data(base64Encoded: token.trimmingCharacters(in: .whitespacesAndNewlines)),
              let claimURLString = String(data: data, encoding: .utf8),
              let claimURL = URL(string: claimURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TTMError.simplefin("invalid setup token")
        }

        let responseData = try await network.postJSON(url: claimURL, body: Data(), bearer: nil)
        guard let accessURL = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !accessURL.isEmpty else {
            throw TTMError.simplefin("claim returned no access URL")
        }

        let now = clock.now()
        let keychainRef = "conn-\(UUID().uuidString)"
        try secrets.write(accessURL, ref: keychainRef)
        try store.saveConnection(ConnectionRecord(
            id: UUID().uuidString,
            name: "SimpleFIN connection",
            keychainRef: keychainRef,
            sfinOrg: nil,
            status: "ok",
            lastError: nil,
            lastSyncedAt: nil,
            createdAt: now
        ))
    }

    public func syncNow() async throws -> SyncOutcome {
        await engine.run()
    }

    // MARK: Net worth

    public func netWorthSummary() async throws -> NetWorthSummary {
        let accounts = try store.allAccounts()
        let balances: [AccountBalance] = accounts.compactMap { rec in
            guard let cls = AccountClass(rawValue: rec.accountClass), !rec.archived else { return nil }
            // Liabilities are kept as positive magnitudes for the rollup; some
            // institutions report debt balances as negative. TODO: per-institution
            // sign handling.
            let cents = cls.contribution == .liability ? abs(rec.balanceCents) : rec.balanceCents
            return AccountBalance(accountClass: cls, balance: Money(cents: cents))
        }
        let propertyValues = try store.latestPropertyValuesCents().map { Money(cents: $0) }
        return NetWorth.summary(accounts: balances, propertyValues: propertyValues, asOf: clock.now())
    }

    public func netWorthSeries(from: UnixTime?, to: UnixTime?) async throws -> [NetWorthPoint] {
        NetWorth.series(snapshots: try store.seriesSnapshots(),
                        propertyValues: try store.seriesPropertyValues(),
                        from: from, to: to)
    }

    // MARK: Categorization

    public func setCategory(transactionId: String, categoryId: String?) async throws {
        try store.setTransactionCategory(id: transactionId, categoryId: categoryId,
                                         source: categoryId == nil ? nil : "manual", updatedAt: clock.now())
    }

    public func upsertRule(_ rule: Rule, apply: RuleApplyMode) async throws {
        let conditionsJSON = String(data: try JSONEncoder().encode(rule.condition), encoding: .utf8) ?? "{}"
        let now = clock.now()
        try store.saveRuleRecord(RuleRecord(
            id: rule.id, name: rule.name, categoryId: rule.categoryId,
            priority: rule.priority, enabled: rule.enabled, conditions: conditionsJSON,
            createdAt: now, updatedAt: now
        ))
        try categorizer.reapply(mode: apply)
    }
}
