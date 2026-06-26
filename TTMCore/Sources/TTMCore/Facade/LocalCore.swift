import Foundation

/// The free, on-device `CoreFacade` implementation: SQLite + on-device SimpleFIN
/// sync + deterministic rules. No backend. The SwiftUI app talks only to this.
public final class LocalCore: CoreFacade {
    let store: Store
    let clock: Clock
    private let secrets: SecretStore
    private let network: NetworkClient
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

    // MARK: Accounts

    public func accounts() async throws -> [AccountSummary] {
        try store.allAccounts().map { rec in
            let nick = rec.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            let renamed = !(nick?.isEmpty ?? true)
            return AccountSummary(
                id: rec.id, name: renamed ? nick! : rec.name, syncedName: rec.name, isRenamed: renamed,
                accountClass: AccountClass(rawValue: rec.accountClass) ?? .unclassified,
                balance: Money(cents: rec.balanceCents), currency: rec.currency, archived: rec.archived)
        }
    }

    public func setAccountClass(accountId: String, accountClass: AccountClass) async throws {
        try store.setAccountClass(id: accountId, accountClass: accountClass.rawValue)
    }

    public func renameAccount(accountId: String, name: String?) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.setAccountNickname(id: accountId, nickname: (trimmed?.isEmpty ?? true) ? nil : trimmed)
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
        let base = NetWorth.summary(accounts: balances, propertyValues: propertyValues, asOf: clock.now())
        // Real-estate equity = gross property value − linked mortgage/HELOC
        // balances (those debts are already counted in liabilities; no double-count).
        let linkedDebt = Money(cents: try store.linkedDebtTotalCents())
        let grossProperty = propertyValues.reduce(Money.zero, +)
        return NetWorthSummary(
            assets: base.assets, liabilities: base.liabilities,
            liquid: base.liquid, investments: base.investments,
            realEstateEquity: grossProperty - linkedDebt,
            securedDebt: base.securedDebt, unsecuredDebt: base.unsecuredDebt, asOf: base.asOf
        )
    }

    public func netWorthSeries(from: UnixTime?, to: UnixTime?) async throws -> [NetWorthPoint] {
        NetWorth.series(snapshots: try store.seriesSnapshots(),
                        propertyValues: try store.seriesPropertyValues(),
                        from: from, to: to)
    }

    // MARK: Categorization

    public func categories() async throws -> [CategorySummary] {
        try store.allCategories().map { CategorySummary(id: $0.id, name: $0.name, kind: $0.kind) }
    }

    public func setCategory(transactionId: String, categoryId: String?) async throws {
        try store.setTransactionCategory(id: transactionId, categoryId: categoryId,
                                         source: categoryId == nil ? nil : "manual", updatedAt: clock.now())
    }

    public func rules() async throws -> [Rule] {
        try categorizer.loadRules()
    }

    public func deleteRule(id: String) async throws {
        try store.deleteRule(id: id)
    }

    public func spending(from: UnixTime, to: UnixTime) async throws -> [SpendingLine] {
        try store.spendingByCategory(from: from, to: to).map {
            SpendingLine(categoryId: $0.id, categoryName: $0.name, amount: Money(cents: $0.cents))
        }
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

    // MARK: Interest & debt cost

    public func setPaymentSplit(transactionId: String, principal: Money, interest: Money, escrow: Money) async throws {
        try store.setPaymentSplit(transactionId: transactionId, principal: principal.cents,
                                  interest: interest.cents, escrow: escrow.cents, now: clock.now())
    }

    public func interestSummary(from: UnixTime, to: UnixTime) async throws -> InterestRollup {
        let rows = try store.interestByAccount(categoryId: DefaultData.interestCategoryId, from: from, to: to)
        let lines = rows.map { InterestLine(accountId: $0.accountId, accountName: $0.name, interest: Money(cents: $0.cents)) }
        let total = lines.reduce(Money.zero) { $0 + $1.interest }
        return InterestRollup(total: total, byAccount: lines)
    }

    // MARK: Transactions

    public func transactions(_ query: TxnQuery) async throws -> [TransactionRecord] {
        try store.transactions(query)
    }

    @discardableResult
    public func detectTransfers() async throws -> Int {
        try Transfers.detect(store: store, now: clock.now(), transferCategoryId: "transfer")
    }

    // MARK: Real estate

    public func addProperty(name: String, kind: String) async throws -> String {
        let id = UUID().uuidString
        try store.saveProperty(PropertyRecord(id: id, name: name, kind: kind, createdAt: clock.now()))
        return id
    }

    public func addPropertyValue(propertyId: String, value: Money, asOf: UnixTime, note: String?) async throws {
        try store.addPropertyValue(PropertyValueRecord(
            id: nil, propertyId: propertyId, valueCents: value.cents, asOf: asOf, note: note, createdAt: clock.now()
        ))
    }

    public func linkPropertyDebt(propertyId: String, accountId: String, role: String) async throws {
        try store.linkDebt(PropertyDebtRecord(propertyId: propertyId, accountId: accountId, role: role))
    }

    public func unlinkPropertyDebt(propertyId: String, accountId: String) async throws {
        try store.unlinkDebt(propertyId: propertyId, accountId: accountId)
    }

    public func properties() async throws -> [PropertySummary] {
        try store.propertySummaries().map {
            PropertySummary(id: $0.id, name: $0.name, value: Money(cents: $0.valueCents), linkedDebt: Money(cents: $0.debtCents))
        }
    }
}
