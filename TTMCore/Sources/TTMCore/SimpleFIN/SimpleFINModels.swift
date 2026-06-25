import Foundation

// SimpleFIN /accounts response, decoded defensively for v1 (payee/memo, org)
// and v2 (connections, transacted_at). Amounts/balances are decimal STRINGS
// and parsed to cents via Money — never Double. See PLAN.md §2.2.

public struct SFAccountSet: Decodable, Sendable {
    public let errors: [String]?
    public let accounts: [SFAccount]

    // beta-bridge returns "errors"; some SimpleFIN servers use "errlist".
    enum CodingKeys: String, CodingKey { case errors, accounts }
}

public struct SFAccount: Decodable, Sendable {
    public let id: String
    public let name: String
    public let currency: String
    public let balance: String
    public let availableBalance: String?
    public let balanceDate: Int64?
    public let org: SFOrg?
    public let transactions: [SFTransaction]?

    enum CodingKeys: String, CodingKey {
        case id, name, currency, balance, org, transactions
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }

    public var balanceCents: Money? { Money(decimalString: balance) }
    public var availableCents: Money? { availableBalance.flatMap { Money(decimalString: $0) } }
}

public struct SFOrg: Decodable, Sendable {
    public let name: String?
    public let domain: String?
    public let sfinURL: String?

    enum CodingKeys: String, CodingKey {
        case name, domain
        case sfinURL = "sfin-url"
    }
}

public struct SFTransaction: Decodable, Sendable {
    public let id: String
    public let posted: Int64?
    public let amount: String
    public let description: String?
    public let payee: String?
    public let memo: String?
    public let pending: Bool?
    public let transactedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, posted, amount, description, payee, memo, pending
        case transactedAt = "transacted_at"
    }

    public var amountCents: Money? { Money(decimalString: amount) }
    public var isPending: Bool { pending ?? (posted == nil || posted == 0) }
}
