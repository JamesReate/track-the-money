import XCTest
@testable import TTMCore

/// Covers the category foundation (CATEGORIZATION_PLAN.md §1/§3/§5): the seeded
/// two-level tree + colors, deterministic auto-coloring, the uncategorized filter,
/// and the reassign/merge/delete semantics that protect transactions and rules.
final class CategoryTests: XCTestCase {
    private struct C: Clock { func now() -> UnixTime { 1_700_000_000 } }

    private func core() throws -> LocalCore {
        final class Secrets: SecretStore, @unchecked Sendable {
            func read(ref: String) throws -> String? { nil }
            func write(_ value: String, ref: String) throws {}
            func delete(ref: String) throws {}
        }
        struct Net: NetworkClient {
            func get(url: URL, basicAuth: BasicAuth?) async throws -> Data { Data() }
            func postJSON(url: URL, body: Data, bearer: String?) async throws -> Data { Data() }
        }
        return try LocalCore(dbPath: ":memory:", secrets: Secrets(), network: Net(), clock: C())
    }

    // MARK: Seed tree

    func testSeedProducesGroupedTreeWithColors() async throws {
        let core = try core()
        let cats = try await core.categories()
        // Entertainment group + its new leaves exist.
        let ent = cats.first { $0.id == "grp-entertainment" }
        XCTAssertNotNil(ent)
        XCTAssertNil(ent?.parentId)                       // a top-level group header
        XCTAssertEqual(cats.first { $0.id == "streaming" }?.parentId, "grp-entertainment")
        XCTAssertEqual(cats.first { $0.id == "concerts" }?.parentId, "grp-entertainment")
        XCTAssertEqual(cats.first { $0.id == "going-out" }?.parentId, "grp-entertainment")
        // Existing leaves reparented under their groups.
        XCTAssertEqual(cats.first { $0.id == "groceries" }?.parentId, "grp-food")
        XCTAssertEqual(cats.first { $0.id == "utilities" }?.parentId, "grp-home")
        // Standalone leaves stay top-level.
        XCTAssertNil(cats.first { $0.id == "auto" }?.parentId)
        // Every category has a color now.
        XCTAssertTrue(cats.allSatisfy { ($0.color?.isEmpty == false) })
        // System categories flagged + flat.
        let transfer = cats.first { $0.id == "transfer" }
        XCTAssertEqual(transfer?.isSystem, true)
        XCTAssertNil(transfer?.parentId)
    }

    func testEnsureCategoriesIsIdempotent() async throws {
        let core = try core()
        let before = try await core.categories().count
        // Re-running the reconcile must neither duplicate nor lose rows.
        try DefaultData.ensureCategories(core.store, now: C().now())
        let after = try await core.categories().count
        XCTAssertEqual(after, before)
    }

    // MARK: Auto color

    func testCreateCategoryAutoAssignsColor() async throws {
        let core = try core()
        let made = try await core.createCategory(name: "Coffee Shops", parentId: "grp-food", kind: "expense", color: nil)
        XCTAssertEqual(made.parentId, "grp-food")
        XCTAssertNotNil(made.color)
        XCTAssertTrue(CategoryPalette.hexes.contains(made.color ?? ""))
    }

    func testNextColorPicksLeastUsedDeterministically() {
        // With the first hue already used twice, it should not be chosen.
        let used = [CategoryPalette.hexes[0], CategoryPalette.hexes[0]]
        let pick = CategoryPalette.nextColor(usedColors: used)
        XCTAssertEqual(pick, CategoryPalette.hexes[1])
    }

    func testCannotNestThreeDeepOrUnderSystem() async throws {
        let core = try core()
        // Under a leaf-with-parent (groceries) → would be 3 levels.
        await XCTAssertThrowsErrorAsync(try await core.createCategory(name: "X", parentId: "groceries", kind: "expense", color: nil))
        // Under a system category.
        await XCTAssertThrowsErrorAsync(try await core.createCategory(name: "X", parentId: "transfer", kind: "expense", color: nil))
    }

    // MARK: Uncategorized filter

    func testUncategorizedFilterAndCount() async throws {
        let core = try core()
        try core.store.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: C().now()))
        try core.store.saveAccount(AccountRecord(id: "a", connectionId: "c", sfinAccountId: "sa", name: "Chk",
            currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil, balanceCents: 0,
            availableCents: nil, balanceDate: nil, archived: false, createdAt: C().now()))
        func txn(_ id: String, _ cat: String?) -> TransactionRecord {
            TransactionRecord(id: id, accountId: "a", sfinTxnId: id, postedAt: 1_699_000_000, transactedAt: nil,
                amountCents: -1000, description: id, payee: id, memo: nil, pending: false,
                categoryId: cat, categorySource: cat == nil ? nil : "manual", isTransfer: false,
                transferGroupId: nil, extraJson: nil, createdAt: C().now(), updatedAt: C().now())
        }
        try core.store.saveTransaction(txn("u1", nil))
        try core.store.saveTransaction(txn("u2", nil))
        try core.store.saveTransaction(txn("c1", "dining"))

        let count = try await core.uncategorizedCount()
        XCTAssertEqual(count, 2)
        let uncat = try await core.transactions(TxnQuery(categorization: .uncategorized))
        XCTAssertEqual(Set(uncat.map { $0.id }), ["u1", "u2"])
        let cat = try await core.transactions(TxnQuery(categorization: .categorized))
        XCTAssertEqual(cat.map { $0.id }, ["c1"])
        let allCount = try await core.transactions(TxnQuery(categorization: .all)).count
        XCTAssertEqual(allCount, 3)
    }

    // MARK: Merge / delete protect transactions and rules

    func testMergeRepointsTransactionsAndRules() async throws {
        let core = try core()
        try core.store.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: C().now()))
        try core.store.saveAccount(AccountRecord(id: "a", connectionId: "c", sfinAccountId: "sa", name: "Chk",
            currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil, balanceCents: 0,
            availableCents: nil, balanceDate: nil, archived: false, createdAt: C().now()))
        try core.store.saveTransaction(TransactionRecord(id: "t", accountId: "a", sfinTxnId: "t", postedAt: 1,
            transactedAt: nil, amountCents: -100, description: "x", payee: "x", memo: nil, pending: false,
            categoryId: "dining", categorySource: "manual", isTransfer: false, transferGroupId: nil,
            extraJson: nil, createdAt: 1, updatedAt: 1))
        try await core.upsertRule(Rule(id: "r1", name: "x", categoryId: "dining", priority: 100, enabled: true,
            condition: Condition(op: .and, clauses: [Clause(field: .description, match: .contains, value: "x")])),
            apply: .forwardOnly)

        try await core.mergeCategory(fromId: "dining", intoId: "groceries")

        XCTAssertNil(try core.store.findCategory(id: "dining"))
        XCTAssertEqual(try core.store.findTransaction(accountId: "a", sfinTxnId: "t")?.categoryId, "groceries")
        let ruleCat = try await core.rules().first { $0.id == "r1" }?.categoryId
        XCTAssertEqual(ruleCat, "groceries")
    }

    func testReassignContentsMovesTxnsAndRulesKeepingBoth() async throws {
        let core = try core()
        try core.store.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
            status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: C().now()))
        try core.store.saveAccount(AccountRecord(id: "a", connectionId: "c", sfinAccountId: "sa", name: "Chk",
            currency: "USD", accountClass: "liquid", subclass: nil, aprBps: nil, balanceCents: 0,
            availableCents: nil, balanceDate: nil, archived: false, createdAt: C().now()))
        try core.store.saveTransaction(TransactionRecord(id: "t", accountId: "a", sfinTxnId: "t", postedAt: 1,
            transactedAt: nil, amountCents: -100, description: "SHELL", payee: "SHELL", memo: nil, pending: false,
            categoryId: "auto", categorySource: "manual", isTransfer: false, transferGroupId: nil,
            extraJson: nil, createdAt: 1, updatedAt: 1))
        try await core.upsertRule(Rule(id: "r1", name: "shell", categoryId: "auto", priority: 100, enabled: true,
            condition: Condition(op: .and, clauses: [Clause(field: .description, match: .contains, value: "SHELL")])),
            apply: .forwardOnly)
        // Promote: add a child "Fuel" under the "auto" leaf, then move auto's contents into it.
        let fuel = try await core.createCategory(name: "Fuel", parentId: "auto", kind: "expense", color: nil)
        try await core.reassignCategoryContents(fromId: "auto", toId: fuel.id)

        // Both categories still exist; the transaction + rule now point at Fuel.
        XCTAssertNotNil(try core.store.findCategory(id: "auto"))
        XCTAssertNotNil(try core.store.findCategory(id: fuel.id))
        XCTAssertEqual(try core.store.findTransaction(accountId: "a", sfinTxnId: "t")?.categoryId, fuel.id)
        let ruleCat = try await core.rules().first { $0.id == "r1" }?.categoryId
        XCTAssertEqual(ruleCat, fuel.id)
    }

    func testDeleteGroupReparentsChildren() async throws {
        let core = try core()
        // Delete the Food group, sending children to top level (reassignTo nil).
        try await core.deleteCategory(id: "grp-food", reassignTo: nil)
        let cats = try await core.categories()
        XCTAssertNil(cats.first { $0.id == "grp-food" })
        XCTAssertNil(cats.first { $0.id == "groceries" }?.parentId)   // bumped to top level, not deleted
        XCTAssertNotNil(cats.first { $0.id == "groceries" })
    }

    func testSystemCategoryDeleteRejected() async throws {
        let core = try core()
        await XCTAssertThrowsErrorAsync(try await core.deleteCategory(id: "transfer", reassignTo: "dining"))
    }
}

/// Async variant of XCTAssertThrowsError (generic over the discarded result).
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) }
    catch { /* expected */ }
}
