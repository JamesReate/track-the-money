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

public struct InterestLine: Equatable, Sendable {
    public let accountId: String
    public let accountName: String
    public let interest: Money
    public init(accountId: String, accountName: String, interest: Money) {
        self.accountId = accountId; self.accountName = accountName; self.interest = interest
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

    // Net worth
    func netWorthSummary() async throws -> NetWorthSummary
    func netWorthSeries(from: UnixTime?, to: UnixTime?) async throws -> [NetWorthPoint]

    // Categorization
    func setCategory(transactionId: String, categoryId: String?) async throws
    func upsertRule(_ rule: Rule, apply: RuleApplyMode) async throws

    // Interest & debt cost
    func setPaymentSplit(transactionId: String, principal: Money, interest: Money, escrow: Money) async throws
    func interestSummary(from: UnixTime, to: UnixTime) async throws -> InterestRollup
}
