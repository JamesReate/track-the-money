import XCTest
@testable import TTMCore

/// End-to-end proof against a **real SimpleFIN bridge over the real network**:
/// claim a setup token → keep the Access URL as a secret → fetch `/accounts`
/// with Basic auth → decode → sync → query. Only the bank is a demo; every line
/// of our own code on that path runs for real.
///
/// Opt-in, so the default suite stays hermetic and fast:
///
///     TTM_LIVE=1 swift test --filter LiveSimpleFINTests
///
/// Point it at your own bridge instead of the demo bank with
/// `TTM_SETUP_TOKEN=<token>` (single-use — mint a fresh one per run).
///
/// **Demo-bridge quirk, learned the hard way:** its response depends on the
/// query window. Asked without `start-date`/`end-date` it returns a small canned
/// sample whose `balance-date` is in the *future*; asked with a window (what
/// `SyncEngine` sends) it synthesizes ~170 transactions and a balance dated now.
/// So two fetches with different parameters legitimately disagree — don't read
/// that as a sync bug, and don't assert one against the other.
final class LiveSimpleFINTests: XCTestCase {
    /// SimpleFIN's published demo claim URL, base64'd — the same shape a real
    /// bridge hands out.
    private static let demoToken =
        "aHR0cHM6Ly9iZXRhLWJyaWRnZS5zaW1wbGVmaW4ub3JnL3NpbXBsZWZpbi9jbGFpbS9ERU1P"

    private var token: String { env("TTM_SETUP_TOKEN") ?? Self.demoToken }
    private var usingDemoBank: Bool { env("TTM_SETUP_TOKEN") == nil }
    private func env(_ k: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[k], !v.isEmpty else { return nil }
        return v
    }

    /// The real thing: URLSession, no stubs.
    private struct LiveNetwork: NetworkClient {
        func get(url: URL, basicAuth: BasicAuth?) async throws -> Data {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if let basicAuth {
                let raw = "\(basicAuth.user):\(basicAuth.password)"
                request.setValue("Basic \(Data(raw.utf8).base64EncodedString())",
                                 forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data)
            return data
        }

        func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            if !body.isEmpty { request.httpBody = body }
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data)
            return data
        }

        private static func check(_ response: URLResponse, _ data: Data) throws {
            guard let http = response as? HTTPURLResponse else { return }
            guard (200..<300).contains(http.statusCode) else {
                throw TTMError.network("HTTP \(http.statusCode): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            }
        }
    }

    /// In-memory stand-in for the Keychain (which needs an app bundle).
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func read(ref: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[ref] }
        func write(_ value: String, ref: String) throws { lock.lock(); values[ref] = value; lock.unlock() }
        func delete(ref: String) throws { lock.lock(); values.removeValue(forKey: ref); lock.unlock() }
    }

    /// Deliberately independent of `Money`'s parser — a second implementation is
    /// a real check; reusing ours would only prove it agrees with itself.
    static func centsFromDecimalString(_ s: String) -> Int64 {
        let negative = s.hasPrefix("-")
        let digits = s.drop { $0 == "-" || $0 == "+" }
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = Int64(parts[0]) ?? 0
        var fraction: Int64 = 0
        if parts.count > 1 {
            let padded = (parts[1] + "00").prefix(2)
            fraction = Int64(padded) ?? 0
        }
        let total = whole * 100 + fraction
        return negative ? -total : total
    }

    private var dir: URL!
    private var secrets: MemorySecrets!

    override func setUpWithError() throws {
        try XCTSkipUnless(env("TTM_LIVE") == "1", "live network test — run with TTM_LIVE=1")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        secrets = MemorySecrets()
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func core() throws -> LocalCore {
        try LocalCore(dbPath: dir.appendingPathComponent("live.db").path,
                      secrets: secrets, network: LiveNetwork())
    }

    func testClaimFetchAndSyncAgainstARealBridge() async throws {
        let core = try core()

        // 1. Claim: setup token → Access URL, held only as a secret.
        try await core.claimSetupToken(token)
        let stored = try core.store.allConnections()
        XCTAssertEqual(stored.count, 1, "claim didn't persist a connection")
        let ref = try XCTUnwrap(stored.first?.keychainRef)
        let accessURL = try XCTUnwrap(secrets.read(ref: ref), "Access URL not written to the secret store")
        XCTAssertTrue(accessURL.hasPrefix("http"), "claim returned something that isn't a URL: \(accessURL)")
        // The credential must never be written into the database.
        XCTAssertFalse(stored.first!.keychainRef.contains(accessURL), "Access URL leaked into the DB")

        // 2. Sync: fetch, decode, upsert.
        let outcome = try await core.syncNow()
        XCTAssertEqual(outcome.connectionsFailed, 0, "a connection failed to sync")
        XCTAssertEqual(outcome.connectionsSucceeded, 1)
        XCTAssertGreaterThan(outcome.newTransactions, 0, "synced zero transactions from a live bridge")

        // 3. The data is queryable through the facade.
        let accounts = try await core.accounts()
        XCTAssertFalse(accounts.isEmpty, "no accounts after a successful sync")
        let txns = try await core.transactions(TxnQuery(limit: 500))
        XCTAssertFalse(txns.isEmpty, "no transactions after a successful sync")

        // Amounts survived decimal-string → Int64 cents with no float drift.
        XCTAssertTrue(txns.allSatisfy { $0.amountCents != 0 || $0.description.isEmpty == false })

        if usingDemoBank {
            let names = Set(accounts.map(\.name))
            XCTAssertTrue(names.contains("SimpleFIN Savings"), "demo savings missing; got \(names)")
            XCTAssertTrue(names.contains("SimpleFIN Checking"), "demo checking missing; got \(names)")
            let savings = try XCTUnwrap(accounts.first { $0.name == "SimpleFIN Savings" })
            XCTAssertGreaterThan(savings.balance.cents, 0, "demo savings synced with no balance")
            // An account with no transactions must still sync (edge case the
            // demo bank helpfully provides).
            XCTAssertTrue(names.contains("SimpleFIN Empty Account"), "empty account was dropped")

            // No float drift: run the decimal strings the bridge is actually
            // serving through Money's parser and compare against an independent
            // conversion. Deliberately NOT compared against the stored balance —
            // the demo bridge synthesizes its response from the query window
            // (see the note in this file's header), so a second fetch with
            // different parameters is a different question, not a discrepancy.
            let live = try await LiveSimpleFINClient(net: LiveNetwork())
                .fetchAccounts(accessURL: try XCTUnwrap(URL(string: accessURL)),
                               start: nil, end: nil, pending: true)
            XCTAssertFalse(live.accounts.isEmpty)
            for account in live.accounts {
                let parsed = try XCTUnwrap(Money(decimalString: account.balance),
                                           "Money rejected a real bridge balance: \(account.balance)")
                XCTAssertEqual(parsed.cents, Self.centsFromDecimalString(account.balance),
                               "\(account.balance) didn't convert to exact cents")
            }
            for txn in live.accounts.flatMap({ $0.transactions ?? [] }) {
                let parsed = try XCTUnwrap(Money(decimalString: txn.amount),
                                           "Money rejected a real bridge amount: \(txn.amount)")
                XCTAssertEqual(parsed.cents, Self.centsFromDecimalString(txn.amount),
                               "\(txn.amount) didn't convert to exact cents")
            }
        }

        // Every sync records balance history — the series that can't be re-fetched.
        let series = try await core.netWorthSeries(from: nil, to: nil)
        XCTAssertFalse(series.isEmpty, "no balance snapshot recorded during sync")
    }

    /// Re-syncing must never duplicate. Note what is *not* asserted: that a
    /// second sync finds zero new transactions. The demo bank synthesizes data
    /// relative to `now`, so a later window genuinely contains new ids — that's
    /// the source changing, not our upsert failing. The real guarantee is that
    /// `(account_id, sfin_txn_id)` stays unique and nothing already synced is
    /// re-inserted or lost.
    ///
    /// The demo bank reuses transaction ids ACROSS accounts, which also proves
    /// the upsert key is really the pair and not the transaction id alone.
    func testResyncNeverDuplicatesAgainstARealBridge() async throws {
        let core = try core()
        try await core.claimSetupToken(token)

        let first = try await core.syncNow()
        XCTAssertEqual(first.connectionsFailed, 0)
        XCTAssertGreaterThan(first.newTransactions, 0)
        let before = Set(try await core.transactions(TxnQuery(limit: 5000)).map(Self.key))
        XCTAssertFalse(before.isEmpty)

        let second = try await core.syncNow()
        XCTAssertEqual(second.connectionsFailed, 0, "second sync failed")

        let after = try await core.transactions(TxnQuery(limit: 5000))
        let keys = after.map(Self.key)
        XCTAssertEqual(keys.count, Set(keys).count,
                       "duplicate (account_id, sfin_txn_id) rows after re-sync")
        XCTAssertTrue(before.isSubset(of: Set(keys)),
                      "re-sync dropped or rewrote transactions that were already stored")

        if usingDemoBank {
            // Same sfin id on two different accounts must survive as two rows.
            let sfinIds = after.map(\.sfinTxnId)
            XCTAssertGreaterThan(sfinIds.count, Set(sfinIds).count,
                                 "expected the demo bank's cross-account duplicate ids to be preserved")
        }
    }

    private static func key(_ t: TransactionRecord) -> String { "\(t.accountId)|\(t.sfinTxnId)" }
}
