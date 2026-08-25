import XCTest
@testable import TTMCore

/// Proves the on-device categorization *seam* (the Apple model itself is not built
/// here): an injected `OnDeviceCategorizer` is reached on a rule miss and can see
/// the transaction + assignable leaves, while the default no-op stays rules-only.
final class OnDeviceCategorizerTests: XCTestCase {
    private struct C: Clock { func now() -> UnixTime { 1_700_000_000 } }
    private final class Secrets: SecretStore, @unchecked Sendable {
        func read(ref: String) throws -> String? { nil }
        func write(_ value: String, ref: String) throws {}
        func delete(ref: String) throws {}
    }
    private struct Net: NetworkClient {
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { Data() }
        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { Data() }
    }

    /// Stand-in for the real Apple Foundation Models / Core ML implementation.
    private struct FakeModel: OnDeviceCategorizer {
        var isAvailable: Bool { true }
        func suggest(_ txn: TxnView, options: [CategoryOption]) async -> CategorySuggestion? {
            guard txn.description.localizedCaseInsensitiveContains("coffee"),
                  let dining = options.first(where: { $0.id == "dining" }) else { return nil }
            return CategorySuggestion(categoryId: dining.id, confidence: 0.92, suggestedRulePayee: txn.payee)
        }
    }

    private func core(model: OnDeviceCategorizer? = nil) throws -> LocalCore {
        if let model {
            return try LocalCore(dbPath: ":memory:", secrets: Secrets(), network: Net(), clock: C(), onDeviceCategorizer: model)
        }
        return try LocalCore(dbPath: ":memory:", secrets: Secrets(), network: Net(), clock: C())
    }

    private func seedUncategorized(_ core: LocalCore) throws {
        try core.store.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: C().now()))
        try core.store.saveAccount(AccountRecord(id: "a", connectionId: "c", sfinAccountId: "sa", name: "Chk",
            currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil, balanceCents: 0,
            availableCents: nil, balanceDate: nil, archived: false, createdAt: C().now()))
        try core.store.saveTransaction(TransactionRecord(id: "t", accountId: "a", sfinTxnId: "t", postedAt: 1,
            transactedAt: nil, amountCents: -575, description: "BLUE BOTTLE COFFEE", payee: "BLUE BOTTLE COFFEE",
            memo: nil, pending: false, categoryId: nil, categorySource: nil, isTransfer: false,
            transferGroupId: nil, extraJson: nil, createdAt: 1, updatedAt: 1))
    }

    func testInjectedModelIsReachedAndScopedToLeaves() async throws {
        let core = try core(model: FakeModel())
        try seedUncategorized(core)
        let s = try await core.suggestCategory(transactionId: "t")
        XCTAssertEqual(s?.categoryId, "dining")           // a leaf under Food
        XCTAssertEqual(s?.confidence ?? 0, 0.92, accuracy: 0.0001)
        XCTAssertEqual(s?.suggestedRulePayee, "BLUE BOTTLE COFFEE")
    }

    func testDefaultIsNoOp() async throws {
        let core = try core()                              // default NoOp → rules-only
        try seedUncategorized(core)
        let s = try await core.suggestCategory(transactionId: "t")
        XCTAssertNil(s)
    }
}
