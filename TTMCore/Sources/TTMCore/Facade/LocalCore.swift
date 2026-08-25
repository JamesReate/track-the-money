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

    /// `onDeviceCategorizer` is the injection point for free on-device AI (Apple
    /// Foundation Models / Core ML). Defaults to a no-op so the free app is
    /// rules-only exactly as today; the app layer injects a real one on capable
    /// devices. TTMCore never imports an Apple ML framework — the impl lives in the
    /// app and conforms to `OnDeviceCategorizer`.
    public init(dbPath: String, secrets: SecretStore, network: NetworkClient, clock: Clock = SystemClock(),
                onDeviceCategorizer: OnDeviceCategorizer = NoOpOnDeviceCategorizer()) throws {
        let database = try Database(path: dbPath)
        self.store = Store(database)
        self.secrets = secrets
        self.network = network
        self.clock = clock
        self.client = LiveSimpleFINClient(net: network)
        self.engine = SyncEngine(store: store, client: client, secrets: secrets, clock: clock)
        self.categorizer = Categorizer(store: store, clock: clock, onDevice: onDeviceCategorizer)
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

    public func debtSeries(from: UnixTime?, to: UnixTime?) async throws -> [DebtPoint] {
        NetWorth.debtSeries(snapshots: try store.debtSeriesSnapshots(), from: from, to: to)
    }

    // MARK: Categorization

    public func categories() async throws -> [CategorySummary] {
        try store.allCategories().map {
            CategorySummary(id: $0.id, name: $0.name, kind: $0.kind,
                            parentId: $0.parentId, color: $0.color, sort: $0.sort)
        }
    }

    public func setCategory(transactionId: String, categoryId: String?) async throws {
        try store.setTransactionCategory(id: transactionId, categoryId: categoryId,
                                         source: categoryId == nil ? nil : "manual", updatedAt: clock.now())
    }

    public func uncategorizedCount() async throws -> Int {
        try store.uncategorizedCount()
    }

    public func suggestCategory(transactionId: String) async throws -> CategorySuggestion? {
        guard let row = try store.matchRow(transactionId: transactionId) else { throw TTMError.notFound }
        let cats = try store.allCategories()
        let nameById = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let groupIds = Set(cats.compactMap { $0.parentId })   // ids used as a parent = groups
        // Offer only assignable expense leaves (no children, not system) — same set
        // the picker shows the user.
        let options = cats
            .filter { !groupIds.contains($0.id) && !DefaultData.systemKinds.contains($0.kind) }
            .map { CategoryOption(id: $0.id, name: $0.name, groupName: $0.parentId.flatMap { nameById[$0] }) }
        let txn = TxnView(description: row.description, payee: row.payee, memo: row.memo,
                          accountId: row.accountId, amountCents: row.amountCents, currency: row.currency)
        return await categorizer.suggest(txn, options: options)
    }

    public func categoryTransactionCounts() async throws -> [String: Int] {
        try store.transactionCountsByCategory()
    }

    // MARK: Category management

    @discardableResult
    public func createCategory(name: String, parentId: String?, kind: String, color: String?) async throws -> CategorySummary {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTMError.invalidOperation("category name is empty") }
        let all = try store.allCategories()
        // A category may not nest under a system category, and only top-level
        // leaves may become parents (we keep the tree to two levels).
        if let pid = parentId {
            guard let parent = all.first(where: { $0.id == pid }) else { throw TTMError.notFound }
            guard !DefaultData.systemKinds.contains(parent.kind) else {
                throw TTMError.invalidOperation("cannot nest under a system category")
            }
            guard parent.parentId == nil else { throw TTMError.invalidOperation("categories nest only two levels deep") }
        }
        let resolvedColor = color ?? CategoryPalette.nextColor(usedColors: all.compactMap { $0.color })
        let nextSort = (all.map { $0.sort }.max() ?? 0) + 1
        let id = "cat-" + UUID().uuidString.prefix(8).lowercased()
        let record = CategoryRecord(id: id, name: trimmed, parentId: parentId, kind: kind,
                                    color: resolvedColor, sort: nextSort, createdAt: clock.now())
        try store.saveCategory(record)
        return CategorySummary(id: id, name: trimmed, kind: kind, parentId: parentId, color: resolvedColor, sort: nextSort)
    }

    public func renameCategory(id: String, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTMError.invalidOperation("category name is empty") }
        guard var rec = try store.findCategory(id: id) else { throw TTMError.notFound }
        rec.name = trimmed
        try store.saveCategory(rec)
    }

    public func recolorCategory(id: String, color: String) async throws {
        guard var rec = try store.findCategory(id: id) else { throw TTMError.notFound }
        rec.color = color
        try store.saveCategory(rec)
    }

    public func moveCategory(id: String, toParentId: String?) async throws {
        guard let rec = try store.findCategory(id: id) else { throw TTMError.notFound }
        guard !DefaultData.systemKinds.contains(rec.kind) else {
            throw TTMError.invalidOperation("system categories can't be grouped")
        }
        if let pid = toParentId {
            guard pid != id else { throw TTMError.invalidOperation("a category can't parent itself") }
            guard let parent = try store.findCategory(id: pid) else { throw TTMError.notFound }
            guard !DefaultData.systemKinds.contains(parent.kind), parent.parentId == nil else {
                throw TTMError.invalidOperation("invalid group")
            }
            // Moving a category that itself has children would create a third
            // level — disallow.
            let children = try store.allCategories().contains { $0.parentId == id }
            guard !children else { throw TTMError.invalidOperation("regroup the subcategories first") }
        }
        try store.setCategoryParent(id: id, parentId: toParentId)
    }

    public func reorderCategories(orderedIds: [String]) async throws {
        for (index, id) in orderedIds.enumerated() {
            try store.setCategorySort(id: id, sort: index)
        }
    }

    public func deleteCategory(id: String, reassignTo: String?) async throws {
        guard let rec = try store.findCategory(id: id) else { throw TTMError.notFound }
        guard !DefaultData.systemKinds.contains(rec.kind) else {
            throw TTMError.invalidOperation("system categories can't be deleted")
        }
        let now = clock.now()
        // Move everything OFF the doomed row before deleting so the FK cascades
        // (children, rules) and SET NULL (transactions) have nothing to destroy.
        if let target = reassignTo {
            guard target != id, try store.findCategory(id: target) != nil else { throw TTMError.notFound }
            try store.reassignTransactions(from: id, to: target, now: now)
            try store.repointRules(from: id, to: target, now: now)
        }
        // A group's children move to the reassignment target (a group) or to top level.
        let reparentTo: String? = {
            guard let target = reassignTo, let t = try? store.findCategory(id: target), t.parentId == nil else { return nil }
            return target
        }()
        try store.reparentChildren(from: id, to: reparentTo)
        try store.deleteCategory(id: id)
    }

    public func reassignCategoryContents(fromId: String, toId: String) async throws {
        guard fromId != toId else { throw TTMError.invalidOperation("cannot move a category onto itself") }
        guard try store.findCategory(id: fromId) != nil, try store.findCategory(id: toId) != nil else { throw TTMError.notFound }
        let now = clock.now()
        try store.reassignTransactions(from: fromId, to: toId, now: now)
        try store.repointRules(from: fromId, to: toId, now: now)
    }

    public func mergeCategory(fromId: String, intoId: String) async throws {
        guard fromId != intoId else { throw TTMError.invalidOperation("cannot merge a category into itself") }
        guard let from = try store.findCategory(id: fromId) else { throw TTMError.notFound }
        guard try store.findCategory(id: intoId) != nil else { throw TTMError.notFound }
        guard !DefaultData.systemKinds.contains(from.kind) else {
            throw TTMError.invalidOperation("system categories can't be merged")
        }
        let now = clock.now()
        try store.reassignTransactions(from: fromId, to: intoId, now: now)
        try store.repointRules(from: fromId, to: intoId, now: now)
        try store.reparentChildren(from: fromId, to: nil)
        try store.deleteCategory(id: fromId)
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
