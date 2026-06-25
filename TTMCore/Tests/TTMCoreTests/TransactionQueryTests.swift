import XCTest
@testable import TTMCore

/// A two-account fixture with a matching transfer pair and searchable text.
private struct TransferFakeClient: SimpleFINClient {
    func fetchAccounts(accessURL: URL, start: UnixTime?, end: UnixTime?, pending: Bool) async throws -> SFAccountSet {
        let json = """
        { "accounts": [
          { "id": "chk", "name": "Checking", "currency": "USD", "balance": "100.00", "balance-date": 1700000000,
            "transactions": [
              { "id": "out", "posted": 1699990000, "amount": "-500.00", "description": "TRANSFER TO SAVINGS" },
              { "id": "coffee", "posted": 1699990500, "amount": "-4.75", "description": "BLUE BOTTLE COFFEE" }
            ] },
          { "id": "sav", "name": "Savings", "currency": "USD", "balance": "500.00", "balance-date": 1700000000,
            "transactions": [
              { "id": "in", "posted": 1699990100, "amount": "500.00", "description": "TRANSFER FROM CHECKING" }
            ] }
        ] }
        """
        return try JSONDecoder().decode(SFAccountSet.self, from: Data(json.utf8))
    }
}

final class TransactionQueryTests: XCTestCase {
    private func core() throws -> (Store, SyncEngine) {
        let store = Store(try Database.inMemory())
        let clock = { () -> Clock in struct C: Clock { func now() -> UnixTime { 1700001000 } }; return C() }()
        try DefaultData.seedIfEmpty(store, now: clock.now())
        final class Secrets: SecretStore, @unchecked Sendable {
            var v: [String: String] = ["r": "https://u:p@beta-bridge.simplefin.org/simplefin"]
            func read(ref: String) throws -> String? { v[ref] }
            func write(_ value: String, ref: String) throws { v[ref] = value }
            func delete(ref: String) throws { v[ref] = nil }
        }
        try store.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
                                                  status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: clock.now()))
        let engine = SyncEngine(store: store, client: TransferFakeClient(), secrets: Secrets(), clock: clock)
        return (store, engine)
    }

    func testFTSSearch() async throws {
        let (store, engine) = try core()
        _ = await engine.run()
        let results = try store.transactions(TxnQuery(searchText: "coffee"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.description, "BLUE BOTTLE COFFEE")
    }

    func testTransferPairDetectedAtSync() async throws {
        let (store, engine) = try core()
        _ = await engine.run()
        let transfers = try store.transactions(TxnQuery(categoryId: "transfer", limit: 10))
        XCTAssertEqual(transfers.count, 2)
        XCTAssertTrue(transfers.allSatisfy { $0.isTransfer })
        // Both legs share a group id.
        XCTAssertEqual(Set(transfers.compactMap { $0.transferGroupId }).count, 1)
    }

    func testFilterByAccountAndDate() async throws {
        let (store, engine) = try core()
        _ = await engine.run()
        let chk = try store.allAccounts().first { $0.sfinAccountId == "chk" }!
        let rows = try store.transactions(TxnQuery(accountId: chk.id))
        XCTAssertEqual(rows.count, 2)   // out + coffee
    }
}
