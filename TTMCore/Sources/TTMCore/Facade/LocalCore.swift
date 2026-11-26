import Foundation
import GRDB

/// The free, on-device `CoreFacade` implementation: SQLite + on-device SimpleFIN
/// sync + deterministic rules. No backend. The SwiftUI app talks only to this.
// `internals` is swapped on restore, so this class is mutable state shared
// across concurrency domains; the lock below makes that safe and `@unchecked`
// tells the compiler we've handled it (same pattern as `Database`).
public final class LocalCore: CoreFacade, @unchecked Sendable {
    /// Everything bound to the open database file. Restoring a backup swaps that
    /// file, so these are rebuilt wholesale rather than mutated — the facade
    /// instance (and every SwiftUI reference to it) survives untouched.
    /// DATA_PORTABILITY_PLAN §5 D3a.
    private final class Internals: Sendable {
        let database: Database
        let store: Store
        let sync: SyncEngine
        let categorizer: Categorizer

        init(dbPath: String, secrets: SecretStore, clock: Clock,
             client: SimpleFINClient, onDevice: OnDeviceCategorizer) throws {
            let database = try Database(path: dbPath)
            let store = Store(database)
            self.database = database
            self.store = store
            self.sync = SyncEngine(store: store, client: client, secrets: secrets, clock: clock)
            self.categorizer = Categorizer(store: store, clock: clock, onDevice: onDevice)
            try DefaultData.seedIfEmpty(store, now: clock.now())
        }
    }

    private let internalsLock = NSLock()
    private var _internals: Internals
    /// Current engine internals. Reads take the lock because a restore can
    /// replace them from another task mid-flight.
    private var internals: Internals {
        internalsLock.lock(); defer { internalsLock.unlock() }
        return _internals
    }

    let clock: Clock
    /// The open store's file. Changes when the active profile switches, so it
    /// is guarded by the same lock as `internals`.
    private var _dbPath: String
    private var dbPath: String {
        internalsLock.lock(); defer { internalsLock.unlock() }
        return _dbPath
    }
    /// nil for a fixed-path store (tests, previews): profile methods then throw
    /// `ProfileError.unavailable`. Guarded by `profileLock`.
    private let profileManager: ProfileManager?
    private let profileLock = NSLock()
    private let secrets: SecretStore
    private let network: NetworkClient
    private let client: SimpleFINClient
    private let onDeviceCategorizer: OnDeviceCategorizer

    // Read through to the current internals, so the ~70 call sites below (and
    // tests reaching for `core.store`) are unaffected by a restore swapping them.
    var store: Store { internals.store }
    private var engine: SyncEngine { internals.sync }
    private var categorizer: Categorizer { internals.categorizer }

    /// `onDeviceCategorizer` is the injection point for free on-device AI (Apple
    /// Foundation Models / Core ML). Defaults to a no-op so the free app is
    /// rules-only exactly as today; the app layer injects a real one on capable
    /// devices. TTMCore never imports an Apple ML framework — the impl lives in the
    /// app and conforms to `OnDeviceCategorizer`.
    public convenience init(dbPath: String, secrets: SecretStore, network: NetworkClient, clock: Clock = SystemClock(),
                            onDeviceCategorizer: OnDeviceCategorizer = NoOpOnDeviceCategorizer()) throws {
        try self.init(dbPath: dbPath, profiles: nil, secrets: secrets, network: network, clock: clock,
                      onDeviceCategorizer: onDeviceCategorizer)
    }

    /// Profile-aware store rooted at `profilesRoot` (PROFILES_PLAN §4.1): opens
    /// the active profile, adopting a pre-profiles `<root>/ttm.db` on first run.
    public convenience init(profilesRoot: URL, secrets: SecretStore, network: NetworkClient,
                            clock: Clock = SystemClock(),
                            onDeviceCategorizer: OnDeviceCategorizer = NoOpOnDeviceCategorizer()) throws {
        let manager = try ProfileManager(root: profilesRoot, clock: clock)
        try self.init(dbPath: manager.activeStorePath, profiles: manager, secrets: secrets, network: network,
                      clock: clock, onDeviceCategorizer: onDeviceCategorizer)
    }

    private init(dbPath: String, profiles: ProfileManager?, secrets: SecretStore, network: NetworkClient,
                 clock: Clock, onDeviceCategorizer: OnDeviceCategorizer) throws {
        let client = LiveSimpleFINClient(net: network)
        self._dbPath = dbPath
        self.profileManager = profiles
        self.secrets = secrets
        self.network = network
        self.clock = clock
        self.client = client
        self.onDeviceCategorizer = onDeviceCategorizer
        self._internals = try Internals(dbPath: dbPath, secrets: secrets, clock: clock,
                                        client: client, onDevice: onDeviceCategorizer)
    }

    // MARK: Connections / sync

    public func claimSetupToken(_ token: String) async throws {
        let accessURL = try await claimAccessURL(token)
        let now = clock.now()
        let keychainRef = Self.newKeychainRef()
        try secrets.write(accessURL, ref: keychainRef)
        try store.saveConnection(ConnectionRecord(
            id: UUID().uuidString,
            name: token == SimpleFINDemo.setupToken ? SimpleFINDemo.connectionName : "SimpleFIN connection",
            keychainRef: keychainRef,
            sfinOrg: nil,
            status: "ok",
            lastError: nil,
            lastSyncedAt: nil,
            createdAt: now
        ))
    }

    public func connections() async throws -> [ConnectionSummary] {
        let accountCounts = Dictionary(grouping: try store.allAccounts(), by: \.connectionId).mapValues(\.count)
        return try store.allConnections().filter { $0.id != Store.manualConnectionId }.map { conn in
            ConnectionSummary(id: conn.id, name: conn.name, org: conn.sfinOrg,
                              state: try state(of: conn), lastError: conn.lastError,
                              lastSyncedAt: conn.lastSyncedAt, accountCount: accountCounts[conn.id] ?? 0)
        }
    }

    public func reconnect(connectionId: String, setupToken: String) async throws {
        guard var conn = try store.allConnections().first(where: { $0.id == connectionId }) else {
            throw TTMError.notFound
        }
        let accessURL = try await claimAccessURL(setupToken)
        // A fresh ref, not an overwrite: the old one may be shared with another
        // profile that came from the same file, and that profile shouldn't
        // silently start syncing with this credential.
        let oldRef = conn.keychainRef
        let newRef = Self.newKeychainRef()
        try secrets.write(accessURL, ref: newRef)
        conn.keychainRef = newRef
        conn.status = "ok"
        conn.lastError = nil
        try store.saveConnection(conn)
        if profileManager != nil {
            try withProfiles { try deleteSecretsIfUnreferenced([oldRef], manager: $0) }
        } else {
            try deleteSecretsIfUnreferenced([oldRef], manager: nil)
        }
    }

    private func state(of conn: ConnectionRecord) throws -> ConnectionState {
        if conn.keychainRef == Store.sampleKeychainRef { return .sample }
        guard try secrets.read(ref: conn.keychainRef) != nil else { return .missingCredential }
        switch conn.status {
        case "needs_auth": return .needsAuth
        case "error":      return .error
        default:           return .connected
        }
    }

    private static func newKeychainRef() -> String { "conn-\(UUID().uuidString)" }

    /// SimpleFIN: base64-decode the setup token to a claim URL, POST to it,
    /// receive the long-lived Access URL. The caller puts it in the SecretStore.
    private func claimAccessURL(_ token: String) async throws -> String {
        guard let claimURL = Self.claimURL(fromSetupToken: token) else {
            throw TTMError.simplefin("That doesn’t look like a SimpleFIN setup token. Copy the whole token from SimpleFIN Bridge and try again.")
        }

        let responseData: Data
        do {
            responseData = try await network.postJSON(url: claimURL, body: Data(), bearer: nil)
        } catch TTMError.network("HTTP 403") {
            // The bridge answers 403 to a token that was already claimed.
            throw TTMError.simplefin("This setup token has already been used. Setup tokens work only once — create a new one in SimpleFIN Bridge.")
        }
        guard let accessURL = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !accessURL.isEmpty,
              URL(string: accessURL) != nil else {
            throw TTMError.simplefin("SimpleFIN didn’t return a connection for this token.")
        }
        return accessURL
    }

    /// Decode a setup token to its claim URL, tolerating what copy/paste does
    /// to it: surrounding or embedded whitespace and line breaks, missing `=`
    /// padding, and the URL-safe base64 alphabet.
    static func claimURL(fromSetupToken token: String) -> URL? {
        var b64 = token.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if b64.count % 4 != 0 { b64 += String(repeating: "=", count: 4 - b64.count % 4) }
        guard let data = Data(base64Encoded: b64),
              let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    public func syncNow() async throws -> SyncOutcome {
        await engine.run()
    }

    // MARK: Accounts

    public func accounts() async throws -> [AccountSummary] {
        let refs = Dictionary(uniqueKeysWithValues: try store.allConnections().map { ($0.id, $0.keychainRef) })
        return try store.allAccounts().map { rec in
            let nick = rec.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            let renamed = !(nick?.isEmpty ?? true)
            return AccountSummary(
                id: rec.id, name: renamed ? nick! : rec.name, syncedName: rec.name, isRenamed: renamed,
                accountClass: AccountClass(rawValue: rec.accountClass) ?? .unclassified,
                balance: Money(cents: rec.balanceCents), currency: rec.currency, archived: rec.archived,
                source: Self.source(keychainRef: refs[rec.connectionId]), balanceDate: rec.balanceDate,
                aprBps: rec.aprBps)
        }
    }

    private static func source(keychainRef: String?) -> AccountSource {
        switch keychainRef {
        case Store.manualKeychainRef: return .manual
        case Store.sampleKeychainRef: return .sample
        default:                      return .synced
        }
    }

    private func source(of account: AccountRecord) throws -> AccountSource {
        Self.source(keychainRef: try store.allConnections().first { $0.id == account.connectionId }?.keychainRef)
    }

    private func requireAccount(_ id: String) throws -> AccountRecord {
        guard let rec = try store.findAccount(id: id) else { throw TTMError.notFound }
        return rec
    }

    private func requireManual(_ id: String) throws -> AccountRecord {
        let rec = try requireAccount(id)
        guard try source(of: rec) == .manual else {
            throw TTMError.invalidOperation("Only manually tracked accounts take a typed-in value.")
        }
        return rec
    }

    /// Upper bound on a typed APR: 100%. Anything above is a typo, not a rate.
    static let maxAPRBps = 10_000

    public func setAccountAPR(accountId: String, aprBps: Int?) async throws {
        let rec = try requireAccount(accountId)
        if let aprBps {
            guard AccountClass(rawValue: rec.accountClass)?.isDebt == true else {
                throw TTMError.invalidOperation("Only debt accounts have an interest rate. Classify it as a debt first.")
            }
            guard (0...Self.maxAPRBps).contains(aprBps) else {
                throw TTMError.invalidOperation("Enter a rate between 0% and 100%.")
            }
        }
        try store.setAccountAPR(id: accountId, aprBps: aprBps)
    }

    public func addManualAccount(name: String, accountClass: AccountClass, balance: Money,
                                 asOf: UnixTime) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTMError.invalidOperation("Give the account a name.") }
        let now = clock.now()
        if !(try store.allConnections().contains { $0.id == Store.manualConnectionId }) {
            try store.saveConnection(ConnectionRecord(
                id: Store.manualConnectionId, name: "Manually tracked", keychainRef: Store.manualKeychainRef,
                sfinOrg: nil, status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: now))
        }
        let id = UUID().uuidString
        try store.saveAccount(AccountRecord(
            id: id, connectionId: Store.manualConnectionId, sfinAccountId: "manual-\(id)", name: trimmed,
            currency: "USD", accountClass: accountClass.rawValue, subclass: nil, aprBps: nil,
            balanceCents: balance.cents, availableCents: nil, balanceDate: asOf, archived: false, createdAt: now))
        try store.upsertSnapshot(accountId: id, balanceCents: balance.cents, balanceDate: asOf, now: now)
        return id
    }

    public func setManualBalance(accountId: String, balance: Money, asOf: UnixTime) async throws {
        _ = try requireManual(accountId)
        try store.upsertSnapshot(accountId: accountId, balanceCents: balance.cents, balanceDate: asOf, now: clock.now())
    }

    public func balanceHistory(accountId: String) async throws -> [BalanceEntry] {
        try store.snapshots(accountId: accountId).map { BalanceEntry(asOf: $0.balanceDate, balance: Money(cents: $0.balanceCents)) }
    }

    public func deleteBalanceEntry(accountId: String, asOf: UnixTime) async throws {
        _ = try requireManual(accountId)
        guard try store.deleteSnapshot(accountId: accountId, balanceDate: asOf) else {
            throw TTMError.invalidOperation("An account needs at least one value. Delete the account instead.")
        }
    }

    public func deleteAccount(accountId: String) async throws {
        let rec = try requireAccount(accountId)
        switch try source(of: rec) {
        case .synced:
            try store.tombstoneAccount(id: accountId)
        case .manual:
            try store.deleteAccount(id: accountId)
        case .sample:
            try store.deleteAccount(id: accountId)
            // Don't leave "Sample data · 0 accounts" behind in Settings.
            if !(try store.allAccounts().contains { $0.connectionId == rec.connectionId }) {
                try store.deleteConnection(id: rec.connectionId)
            }
        }
    }

    public func restoreAccount(accountId: String) async throws {
        _ = try requireAccount(accountId)
        try store.setAccountArchived(id: accountId, archived: false)
    }

    public func setAccountClass(accountId: String, accountClass: AccountClass) async throws {
        try store.setAccountClass(id: accountId, accountClass: accountClass.rawValue)
    }

    public func renameAccount(accountId: String, name: String?) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A manual account has no bank name to fall back to: the name is the name.
        if let rec = try store.findAccount(id: accountId), try source(of: rec) == .manual {
            guard let trimmed, !trimmed.isEmpty else { return }
            try store.setAccountName(id: accountId, name: trimmed)
            return
        }
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

    // MARK: Backup & restore (docs/plans/DATA_PORTABILITY_PLAN.md)

    /// Snapshot the store to a temp file the app layer hands to the exporter.
    public func exportBackup() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(BackupManager.suggestedFilename(now: clock.now()))
        return try BackupManager.export(from: internals.database, to: url)
    }

    public func inspectBackup(at url: URL) async throws -> BackupInfo {
        try BackupManager.inspect(at: url)
    }

    /// Replace everything with the given backup. Validates before touching the
    /// store and rolls back to the pre-restore copy on any failure.
    @discardableResult
    public func restoreBackup(from url: URL) async throws -> BackupInfo {
        try BackupManager.restore(from: url, into: dbPath,
                                  closeLive: { [self] in try internals.database.close() },
                                  reopen: { [self] in try rebuildInternals() })
    }

    public func canUndoRestore() async -> Bool {
        BackupManager.hasUndo(livePath: dbPath)
    }

    public func undoRestore() async throws {
        try BackupManager.undo(livePath: dbPath,
                               closeLive: { [self] in try internals.database.close() },
                               reopen: { [self] in try rebuildInternals() })
    }

    /// Rebind Store/SyncEngine/Categorizer onto whatever file now sits at
    /// `dbPath`. Migrations run here, so an older backup upgrades itself.
    private func rebuildInternals() throws {
        try rebind(to: dbPath)
    }

    /// Open `path` and make it the live store. The old internals stay in place
    /// until the new ones are built, so a failure here leaves nothing changed.
    private func rebind(to path: String) throws {
        let fresh = try Internals(dbPath: path, secrets: secrets, clock: clock,
                                  client: client, onDevice: onDeviceCategorizer)
        internalsLock.lock(); _internals = fresh; _dbPath = path; internalsLock.unlock()
    }

    // MARK: Profiles (docs/plans/PROFILES_PLAN.md)

    /// Run `body` against the profile registry, serialized.
    private func withProfiles<T>(_ body: (ProfileManager) throws -> T) throws -> T {
        guard let manager = profileManager else { throw ProfileError.unavailable }
        profileLock.lock(); defer { profileLock.unlock() }
        return try body(manager)
    }

    public func profiles() async throws -> [ProfileSummary] {
        try withProfiles { $0.summaries() }
    }

    public func activeProfile() async throws -> ProfileSummary {
        try withProfiles { try $0.summary(id: $0.activeId) }
    }

    public func createProfile(name: String, kind: ProfileKind) async throws -> ProfileSummary {
        try withProfiles { try $0.summary(id: $0.create(name: name, kind: kind).id) }
    }

    public func switchProfile(id: String) async throws {
        try withProfiles { manager in
            guard id != manager.activeId else { return }
            _ = try manager.summary(id: id)               // exists?
            let previous = dbPath
            try internals.database.close()
            do {
                try rebind(to: manager.storePath(for: id))
            } catch {
                try? rebind(to: previous)                 // never leave the app without a store
                throw error
            }
            try manager.setActive(id)
        }
    }

    public func renameProfile(id: String, name: String) async throws {
        try withProfiles { try $0.rename(id, to: name) }
    }

    public func setProfileKind(id: String, kind: ProfileKind) async throws {
        try withProfiles { try $0.setKind(id, to: kind) }
    }

    public func deleteProfile(id: String) async throws {
        try withProfiles { manager in
            guard id != manager.activeId else { throw ProfileError.cannotDeleteActive }
            guard manager.summaries().count > 1 else { throw ProfileError.cannotDeleteLast }
            let path = manager.storePath(for: id)
            let refs = ((try? Self.keychainRefs(atPath: path)) ?? [])
                + ((try? Self.keychainRefs(atPath: path + BackupManager.preRestoreSuffix)) ?? [])
            try manager.delete(id)
            // After unregistering, so the profile's own refs don't count as "in use".
            try deleteSecretsIfUnreferenced(refs, manager: manager)
        }
    }

    public func importProfile(from url: URL, name: String, kind: ProfileKind) async throws -> ProfileSummary {
        _ = try BackupManager.inspect(at: url)            // validate before anything is created
        return try withProfiles { manager in
            let id = try manager.reserveDirectory()
            do {
                let path = manager.storePath(for: id)
                try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: path))
                try rekeyConnections(atPath: path)
                return try manager.summary(id: manager.register(id: id, name: name, kind: kind).id)
            } catch {
                manager.discardDirectory(id)
                throw error
            }
        }
    }

    /// Give every real connection in an imported store its own Keychain ref,
    /// copying the secret across when the old ref resolves on this device. Each
    /// profile then owns its Keychain items outright, so deleting or
    /// reconnecting one never reaches into another (PROFILES_PLAN §4.3).
    private func rekeyConnections(atPath path: String) throws {
        let database = try Database(path: path)           // migrates an older file forward
        defer { try? database.close() }
        let store = Store(database)
        for var conn in try store.allConnections() where !Store.localKeychainRefs.contains(conn.keychainRef) {
            let newRef = Self.newKeychainRef()
            if let secret = try secrets.read(ref: conn.keychainRef) {
                try secrets.write(secret, ref: newRef)
            }
            conn.keychainRef = newRef
            try store.saveConnection(conn)
        }
    }

    /// The `keychain_ref`s a store file points at. A plain query, not a
    /// `Database` open, so it never runs migrations on (say) an undo copy.
    private static func keychainRefs(atPath path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.read { try String.fetchAll($0, sql: "SELECT keychain_ref FROM connections") }
    }

    /// Delete secrets that no store still points at — including each profile's
    /// undo copy, so "Undo last restore" brings back a working connection.
    /// Stores restored from the same backup can share refs, so ownership is
    /// checked, not assumed. Pass the manager from inside `withProfiles`.
    private func deleteSecretsIfUnreferenced(_ refs: [String], manager: ProfileManager?) throws {
        let candidates = Set(refs).subtracting(Store.localKeychainRefs)
        guard !candidates.isEmpty else { return }
        var inUse = Set(try store.allConnections().map(\.keychainRef))
        var paths = [dbPath + BackupManager.preRestoreSuffix]
        if let manager {
            for profile in manager.summaries() {
                let path = manager.storePath(for: profile.id)
                if !profile.isActive { paths.append(path) }
                paths.append(path + BackupManager.preRestoreSuffix)
            }
        }
        // If any store can't be read, we can't prove a secret is unused — keep them all.
        for path in Set(paths) {
            guard let refs = try? Self.keychainRefs(atPath: path) else { return }
            inUse.formUnion(refs)
        }
        for ref in candidates.subtracting(inUse) { try? secrets.delete(ref: ref) }
    }
}
