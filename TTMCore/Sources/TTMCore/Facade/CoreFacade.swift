import Foundation

// The single app-facing surface of TTMCore (TECH_DESIGN §13.3). The SwiftUI app
// talks ONLY to this protocol — never to GRDB, the sync engine, or the rules
// engine directly. Freezing this contract is what lets the Rust port swap the
// implementation underneath without changing UI call sites.

public struct NetWorthSummary: Equatable, Sendable {
    public let assets: Money
    public let liabilities: Money
    public var netWorth: Money { assets - liabilities }
    public let liquid: Money
    public let investments: Money
    public let realEstateEquity: Money
    public let securedDebt: Money
    public let unsecuredDebt: Money
    public let asOf: UnixTime

    public init(assets: Money, liabilities: Money, liquid: Money, investments: Money,
                realEstateEquity: Money, securedDebt: Money, unsecuredDebt: Money, asOf: UnixTime) {
        self.assets = assets; self.liabilities = liabilities
        self.liquid = liquid; self.investments = investments
        self.realEstateEquity = realEstateEquity
        self.securedDebt = securedDebt; self.unsecuredDebt = unsecuredDebt
        self.asOf = asOf
    }
}

public struct SyncOutcome: Equatable, Sendable {
    public let connectionsSucceeded: Int
    public let connectionsFailed: Int
    public let newTransactions: Int
    public init(connectionsSucceeded: Int, connectionsFailed: Int, newTransactions: Int) {
        self.connectionsSucceeded = connectionsSucceeded
        self.connectionsFailed = connectionsFailed
        self.newTransactions = newTransactions
    }
}

public enum RuleApplyMode: Sendable { case forwardOnly, backfill, rerunAll }

/// Filter transactions by whether they carry a category (CATEGORIZATION_PLAN.md §4).
public enum CategorizationFilter: Sendable, Equatable, CaseIterable { case all, categorized, uncategorized }

public struct TxnQuery: Sendable {
    public var accountId: String?
    public var categoryId: String?
    public var categorization: CategorizationFilter
    public var from: UnixTime?
    public var to: UnixTime?
    public var searchText: String?
    public var includePending: Bool
    public var limit: Int
    public init(accountId: String? = nil, categoryId: String? = nil,
                categorization: CategorizationFilter = .all, from: UnixTime? = nil,
                to: UnixTime? = nil, searchText: String? = nil, includePending: Bool = true, limit: Int = 100) {
        self.accountId = accountId; self.categoryId = categoryId; self.categorization = categorization
        self.from = from; self.to = to
        self.searchText = searchText; self.includePending = includePending; self.limit = limit
    }
}

public struct InterestLine: Equatable, Sendable {
    public let accountId: String
    public let accountName: String
    public let interest: Money
    public init(accountId: String, accountName: String, interest: Money) {
        self.accountId = accountId; self.accountName = accountName; self.interest = interest
    }
}

public struct CategorySummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let parentId: String?      // nil = top-level (a group header, or a standalone leaf)
    public let color: String?         // "#RRGGBB"; nil falls back to a neutral tone in the UI
    public let sort: Int
    /// System categories (Income/Transfer/Interest/Uncategorized) can't be
    /// deleted, regrouped, or used as a group parent.
    public var isSystem: Bool { DefaultData.systemKinds.contains(kind) }
    public init(id: String, name: String, kind: String, parentId: String? = nil,
                color: String? = nil, sort: Int = 0) {
        self.id = id; self.name = name; self.kind = kind
        self.parentId = parentId; self.color = color; self.sort = sort
    }
}

public struct SpendingLine: Equatable, Sendable, Identifiable {
    public let categoryId: String
    public let categoryName: String
    public let amount: Money
    public var id: String { categoryId }
    public init(categoryId: String, categoryName: String, amount: Money) {
        self.categoryId = categoryId; self.categoryName = categoryName; self.amount = amount
    }
}

public struct AccountSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String          // display name (nickname ?? syncedName)
    public let syncedName: String    // the name SimpleFIN reports
    public let isRenamed: Bool
    public let accountClass: AccountClass
    public let balance: Money
    public let currency: String
    public let archived: Bool
    public init(id: String, name: String, syncedName: String, isRenamed: Bool,
                accountClass: AccountClass, balance: Money, currency: String, archived: Bool) {
        self.id = id; self.name = name; self.syncedName = syncedName; self.isRenamed = isRenamed
        self.accountClass = accountClass; self.balance = balance; self.currency = currency; self.archived = archived
    }
}

public struct PropertySummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let value: Money
    public let linkedDebt: Money
    public var equity: Money { value - linkedDebt }
    public init(id: String, name: String, value: Money, linkedDebt: Money) {
        self.id = id; self.name = name; self.value = value; self.linkedDebt = linkedDebt
    }
}

public struct InterestRollup: Equatable, Sendable {
    public let total: Money
    public let byAccount: [InterestLine]   // descending by interest paid
    public init(total: Money, byAccount: [InterestLine]) { self.total = total; self.byAccount = byAccount }
}

/// Where a SimpleFIN connection stands *on this device* (PROFILES_PLAN §4.7).
public enum ConnectionState: String, Equatable, Sendable {
    /// Credential present in the Keychain and the last sync (if any) was fine.
    case connected
    /// The row exists but this device's Keychain holds nothing under its ref —
    /// typically a store restored or imported from another device.
    case missingCredential
    /// The bridge refused the credential (HTTP 403); claim a new token.
    case needsAuth
    /// The last sync failed for some other reason (see `lastError`).
    case error
    /// Sample-data connection: no credential by design, never synced.
    case sample

    /// Re-linking with a fresh setup token would fix it.
    public var canReconnect: Bool { self == .missingCredential || self == .needsAuth || self == .error }
}

public struct ConnectionSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let org: String?
    public let state: ConnectionState
    public let lastError: String?
    public let lastSyncedAt: UnixTime?
    public let accountCount: Int
    public init(id: String, name: String, org: String?, state: ConnectionState,
                lastError: String?, lastSyncedAt: UnixTime?, accountCount: Int) {
        self.id = id; self.name = name; self.org = org; self.state = state
        self.lastError = lastError; self.lastSyncedAt = lastSyncedAt; self.accountCount = accountCount
    }
}

/// The contract every TTMCore implementation (Swift now, Rust later) satisfies.
public protocol CoreFacade: Sendable {
    // Connections / sync
    func claimSetupToken(_ token: String) async throws
    /// The active profile's connections and whether each has a working
    /// credential on this device.
    func connections() async throws -> [ConnectionSummary]
    /// Attach a freshly claimed Access URL to an *existing* connection, so its
    /// accounts and history continue rather than being duplicated under a new one.
    func reconnect(connectionId: String, setupToken: String) async throws
    func syncNow() async throws -> SyncOutcome
    func loadSampleData() async throws   // demo content; no network

    // Accounts
    func accounts() async throws -> [AccountSummary]
    func setAccountClass(accountId: String, accountClass: AccountClass) async throws
    /// Set a display nickname (nil/empty reverts to the SimpleFIN name). The
    /// account id is unchanged, so syncing continues unaffected.
    func renameAccount(accountId: String, name: String?) async throws

    // Net worth
    func netWorthSummary() async throws -> NetWorthSummary
    func netWorthSeries(from: UnixTime?, to: UnixTime?) async throws -> [NetWorthPoint]
    /// Debt magnitude over time, split secured vs unsecured (stacked-area chart).
    func debtSeries(from: UnixTime?, to: UnixTime?) async throws -> [DebtPoint]

    // Categorization
    func categories() async throws -> [CategorySummary]
    func setCategory(transactionId: String, categoryId: String?) async throws
    /// Free, on-device AI suggestion for one uncategorized transaction (nil if no
    /// model is available or it declines). Never applied automatically — the UI
    /// surfaces it for confirmation. Paid Claude remains a separate, smarter path.
    func suggestCategory(transactionId: String) async throws -> CategorySuggestion?
    /// Count of posted+pending transactions with no category (drives the review badge).
    func uncategorizedCount() async throws -> Int
    /// Transaction count per assigned category id (for the manager + delete prompts).
    func categoryTransactionCounts() async throws -> [String: Int]
    func rules() async throws -> [Rule]
    func upsertRule(_ rule: Rule, apply: RuleApplyMode) async throws
    func deleteRule(id: String) async throws

    // Category management (CATEGORIZATION_PLAN.md §5). Auto-assigns a color when
    // `color` is nil; `parentId` nil creates a top-level category. Returns the new row.
    @discardableResult
    func createCategory(name: String, parentId: String?, kind: String, color: String?) async throws -> CategorySummary
    func renameCategory(id: String, name: String) async throws
    func recolorCategory(id: String, color: String) async throws
    /// Move under a group (`toParentId`) or to top level (nil). System categories reject.
    func moveCategory(id: String, toParentId: String?) async throws
    /// Persist a new display order by assigning `sort` from the given sequence.
    func reorderCategories(orderedIds: [String]) async throws
    /// Repoint this category's transactions + rules (+ children, if a group) onto
    /// `reassignTo`, then delete it. System categories reject.
    func deleteCategory(id: String, reassignTo: String?) async throws
    /// Merge `fromId` into `intoId`: repoint transactions + rules, then delete source.
    func mergeCategory(fromId: String, intoId: String) async throws
    /// Move a category's transactions + rules onto another, leaving BOTH in place.
    /// Used for "graceful promotion": when a leaf gains its first child it becomes a
    /// group header, and its directly-assigned transactions move into a subcategory.
    func reassignCategoryContents(fromId: String, toId: String) async throws

    // Spending
    func spending(from: UnixTime, to: UnixTime) async throws -> [SpendingLine]

    // Interest & debt cost
    func setPaymentSplit(transactionId: String, principal: Money, interest: Money, escrow: Money) async throws
    func interestSummary(from: UnixTime, to: UnixTime) async throws -> InterestRollup

    // Transactions
    func transactions(_ query: TxnQuery) async throws -> [TransactionRecord]
    @discardableResult func detectTransfers() async throws -> Int

    // Backup & restore (docs/plans/DATA_PORTABILITY_PLAN.md). The file is a
    // complete SQLite snapshot; restore replaces everything and never merges.
    // Secrets stay in the Keychain, so a backup carries no SimpleFIN access URL.
    /// Write a snapshot to a temp file and return its URL for the app's exporter.
    func exportBackup() async throws -> URL
    /// Validate + summarize a candidate file without touching the live store.
    func inspectBackup(at url: URL) async throws -> BackupInfo
    /// Replace the store with the backup, keeping one generation of undo.
    @discardableResult
    func restoreBackup(from url: URL) async throws -> BackupInfo
    /// Is a pre-restore copy still available to roll back to?
    func canUndoRestore() async -> Bool
    /// Put back the store the last restore replaced. Consumes the undo.
    func undoRestore() async throws

    // Profiles (docs/plans/PROFILES_PLAN.md): independent data sets on this
    // device, one active at a time. Every other method acts on the active one.
    func profiles() async throws -> [ProfileSummary]
    func activeProfile() async throws -> ProfileSummary
    /// Register a new, empty profile. Does not switch to it.
    func createProfile(name: String, kind: ProfileKind) async throws -> ProfileSummary
    /// Close the active store and open another profile's, in place.
    func switchProfile(id: String) async throws
    func renameProfile(id: String, name: String) async throws
    func setProfileKind(id: String, kind: ProfileKind) async throws
    /// Delete an inactive profile's store and the Keychain items only it uses.
    func deleteProfile(id: String) async throws
    /// Validate a backup file and add it as a new profile (does not switch).
    /// Never touches the active store.
    func importProfile(from url: URL, name: String, kind: ProfileKind) async throws -> ProfileSummary

    // Real estate
    func addProperty(name: String, kind: String) async throws -> String
    func addPropertyValue(propertyId: String, value: Money, asOf: UnixTime, note: String?) async throws
    func linkPropertyDebt(propertyId: String, accountId: String, role: String) async throws
    func unlinkPropertyDebt(propertyId: String, accountId: String) async throws
    func properties() async throws -> [PropertySummary]
}
