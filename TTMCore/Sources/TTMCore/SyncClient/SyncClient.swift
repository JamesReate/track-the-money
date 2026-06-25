import Foundation

// Device-side client for the PAID zero-knowledge relay (contract:
// /contract/openapi.yaml). Pushes sealed records, pulls peers' sealed records,
// publishes/fetches household public keys, and proxies AI categorize. Used only
// by signed-in paid users; the free app never touches this.
//
// TODO(M2.9–M2.11): implement against NetworkClient + RecordSealer.

public protocol SyncClient: Sendable {
    func publishPublicKey(keyId: String, publicKey: Data) async throws
    func householdKeys() async throws -> [WrappedKeyRecipient]
    func push(_ records: [SealedRecord], deviceId: String) async throws -> UnixTime   // new cursor
    func pull(since: UnixTime) async throws -> (cursor: UnixTime, records: [SealedRecord])
    func aiCategorize(_ items: [AICategorizeItem], categories: [String]) async throws -> [AISuggestion]
}

public struct AICategorizeItem: Sendable, Encodable {
    public let txnId: String
    public let description: String
    public let payee: String?
    public let amountCents: Int64
    public init(txnId: String, description: String, payee: String?, amountCents: Int64) {
        self.txnId = txnId; self.description = description; self.payee = payee; self.amountCents = amountCents
    }
}

public struct AISuggestion: Sendable, Decodable {
    public let txnId: String
    public let category: String
    public let confidence: Double
    public let rationale: String?
}
