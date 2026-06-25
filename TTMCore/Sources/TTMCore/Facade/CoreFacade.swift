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

public struct TxnQuery: Sendable {
    public var accountId: String?
    public var categoryId: String?
    public var from: UnixTime?
    public var to: UnixTime?
    public var searchText: String?
    public var includePending: Bool
    public var limit: Int
    public init(accountId: String? = nil, categoryId: String? = nil, from: UnixTime? = nil,
                to: UnixTime? = nil, searchText: String? = nil, includePending: Bool = true, limit: Int = 100) {
        self.accountId = accountId; self.categoryId = categoryId; self.from = from; self.to = to
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
    public init(id: String, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
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
    public let name: String
    public let accountClass: AccountClass
    public let balance: Money
    public let currency: String
    public let archived: Bool
    public init(id: String, name: String, accountClass: AccountClass, balance: Money, currency: String, archived: Bool) {
        self.id = id; self.name = name; self.accountClass = accountClass
        self.balance = balance; self.currency = currency; self.archived = archived
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

/// The contract every TTMCore implementation (Swift now, Rust later) satisfies.
public protocol CoreFacade: Sendable {
    // Connections / sync
    func claimSetupToken(_ token: String) async throws
    func syncNow() async throws -> SyncOutcome
    func loadSampleData() async throws   // demo content; no network

    // Accounts
    func accounts() async throws -> [AccountSummary]
    func setAccountClass(accountId: String, accountClass: AccountClass) async throws

    // Net worth
    func netWorthSummary() async throws -> NetWorthSummary
    func netWorthSeries(from: UnixTime?, to: UnixTime?) async throws -> [NetWorthPoint]

    // Categorization
    func categories() async throws -> [CategorySummary]
    func setCategory(transactionId: String, categoryId: String?) async throws
    func rules() async throws -> [Rule]
    func upsertRule(_ rule: Rule, apply: RuleApplyMode) async throws
    func deleteRule(id: String) async throws

    // Spending
    func spending(from: UnixTime, to: UnixTime) async throws -> [SpendingLine]

    // Interest & debt cost
    func setPaymentSplit(transactionId: String, principal: Money, interest: Money, escrow: Money) async throws
    func interestSummary(from: UnixTime, to: UnixTime) async throws -> InterestRollup

    // Transactions
    func transactions(_ query: TxnQuery) async throws -> [TransactionRecord]
    @discardableResult func detectTransfers() async throws -> Int

    // Real estate
    func addProperty(name: String, kind: String) async throws -> String
    func addPropertyValue(propertyId: String, value: Money, asOf: UnixTime, note: String?) async throws
    func linkPropertyDebt(propertyId: String, accountId: String, role: String) async throws
    func unlinkPropertyDebt(propertyId: String, accountId: String) async throws
    func properties() async throws -> [PropertySummary]
}
