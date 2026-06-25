import Foundation
import GRDB

// GRDB row types. CodingKeys map Swift properties to exact snake_case column
// names (no conversion strategy) so the mapping is explicit and verifiable.
// Money is stored as Int64 cents; callers wrap/unwrap via Money at the boundary.

public struct ConnectionRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "connections"
    public var id: String
    public var name: String
    public var keychainRef: String
    public var sfinOrg: String?
    public var status: String
    public var lastError: String?
    public var lastSyncedAt: Int64?
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case keychainRef = "keychain_ref"
        case sfinOrg = "sfin_org"
        case lastError = "last_error"
        case lastSyncedAt = "last_synced_at"
        case createdAt = "created_at"
    }
}

public struct AccountRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "accounts"
    public var id: String
    public var connectionId: String
    public var sfinAccountId: String
    public var name: String
    public var currency: String
    public var accountClass: String          // column "class"
    public var subclass: String?
    public var aprBps: Int?
    public var balanceCents: Int64
    public var availableCents: Int64?
    public var balanceDate: Int64?
    public var archived: Bool
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, currency, subclass, archived
        case connectionId = "connection_id"
        case sfinAccountId = "sfin_account_id"
        case accountClass = "class"
        case aprBps = "apr_bps"
        case balanceCents = "balance_cents"
        case availableCents = "available_cents"
        case balanceDate = "balance_date"
        case createdAt = "created_at"
    }
}

public struct BalanceSnapshotRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "balance_snapshots"
    public var id: Int64?
    public var accountId: String
    public var balanceCents: Int64
    public var availableCents: Int64?
    public var balanceDate: Int64
    public var recordedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case balanceCents = "balance_cents"
        case availableCents = "available_cents"
        case balanceDate = "balance_date"
        case recordedAt = "recorded_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct TransactionRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transactions"
    public var id: String
    public var accountId: String
    public var sfinTxnId: String
    public var postedAt: Int64?
    public var transactedAt: Int64?
    public var amountCents: Int64
    public var description: String
    public var payee: String?
    public var memo: String?
    public var pending: Bool
    public var categoryId: String?
    public var categorySource: String?
    public var isTransfer: Bool
    public var transferGroupId: String?
    public var extraJson: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, description, payee, memo, pending
        case accountId = "account_id"
        case sfinTxnId = "sfin_txn_id"
        case postedAt = "posted_at"
        case transactedAt = "transacted_at"
        case amountCents = "amount_cents"
        case categoryId = "category_id"
        case categorySource = "category_source"
        case isTransfer = "is_transfer"
        case transferGroupId = "transfer_group_id"
        case extraJson = "extra_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CategoryRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "categories"
    public var id: String
    public var name: String
    public var parentId: String?
    public var kind: String
    public var color: String?
    public var sort: Int
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, kind, color, sort
        case parentId = "parent_id"
        case createdAt = "created_at"
    }
}

public struct RuleRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "rules"
    public var id: String
    public var name: String
    public var categoryId: String
    public var priority: Int
    public var enabled: Bool
    public var conditions: String       // JSON-encoded Condition
    public var createdAt: Int64
    public var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, priority, enabled, conditions
        case categoryId = "category_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
