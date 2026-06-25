import Foundation
import Observation
import TTMCore

/// Observable view-model bridging SwiftUI to the `CoreFacade`. Owns one facade
/// instance; all screens read its published state and call its async actions.
@MainActor
@Observable
public final class AppModel {
    private let core: CoreFacade

    public var netWorth: NetWorthSummary?
    public var series: [NetWorthPoint] = []
    public var accounts: [AccountSummary] = []
    public var recentTransactions: [TransactionRecord] = []
    public var properties: [PropertySummary] = []
    public var interest: InterestRollup?
    public var categories: [CategorySummary] = []
    public var rules: [Rule] = []
    public var spending: [SpendingLine] = []
    public var statusMessage = ""
    public var isSyncing = false

    public init(core: CoreFacade) { self.core = core }

    /// Live model backed by SQLite in Application Support + Keychain + URLSession.
    public static func live() throws -> AppModel {
        let core = try LocalCore(dbPath: try databasePath(),
                                 secrets: KeychainSecretStore(),
                                 network: URLSessionNetworkClient())
        return AppModel(core: core)
    }

    public func refresh() async {
        do {
            netWorth = try await core.netWorthSummary()
            series = try await core.netWorthSeries(from: nil, to: nil)
            accounts = try await core.accounts().filter { !$0.archived }
            recentTransactions = try await core.transactions(TxnQuery(limit: 50))
            properties = try await core.properties()
            interest = try await core.interestSummary(from: 0, to: 4_102_444_800) // through ~2100
            categories = try await core.categories()
            rules = try await core.rules()
            spending = try await core.spending(from: 0, to: 4_102_444_800)
        } catch {
            statusMessage = "Load failed: \(error)"
        }
    }

    public func categoryName(_ id: String?) -> String {
        guard let id else { return "Uncategorized" }
        return categories.first { $0.id == id }?.name ?? id
    }

    // MARK: Categorization actions

    public func setCategory(transactionId: String, categoryId: String?) async {
        try? await core.setCategory(transactionId: transactionId, categoryId: categoryId)
        await refresh()
    }

    /// Build a "description contains <payee>" rule → category, apply to past + future.
    public func createRule(fromText text: String, categoryId: String) async {
        let id = "rule-\(UUID().uuidString.prefix(8))"
        let rule = Rule(id: id, name: text, categoryId: categoryId, priority: 100, enabled: true,
                        condition: Condition(op: .and, clauses: [
                            Clause(field: .description, match: .contains, value: text)
                        ]))
        try? await core.upsertRule(rule, apply: .backfill)
        await refresh()
    }

    public func toggleRule(_ rule: Rule) async {
        let updated = Rule(id: rule.id, name: rule.name, categoryId: rule.categoryId,
                           priority: rule.priority, enabled: !rule.enabled, condition: rule.condition)
        try? await core.upsertRule(updated, apply: .forwardOnly)
        await refresh()
    }

    public func deleteRule(_ id: String) async {
        try? await core.deleteRule(id: id)
        await refresh()
    }

    // MARK: Real estate actions

    public func addProperty(name: String, value: Money) async {
        guard let id = try? await core.addProperty(name: name, kind: "real_estate") else { return }
        try? await core.addPropertyValue(propertyId: id, value: value, asOf: nowUnix(), note: nil)
        await refresh()
    }

    public func addPropertyValue(propertyId: String, value: Money) async {
        try? await core.addPropertyValue(propertyId: propertyId, value: value, asOf: nowUnix(), note: nil)
        await refresh()
    }

    public func linkDebt(propertyId: String, accountId: String) async {
        try? await core.linkPropertyDebt(propertyId: propertyId, accountId: accountId, role: "mortgage")
        await refresh()
    }

    private func nowUnix() -> UnixTime { Int64(Date().timeIntervalSince1970) }

    public func search(_ text: String) async {
        let query = text.isEmpty ? TxnQuery(limit: 50) : TxnQuery(searchText: text, limit: 100)
        recentTransactions = (try? await core.transactions(query)) ?? []
    }

    public func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcome = try await core.syncNow()
            statusMessage = "Synced: +\(outcome.newTransactions) new · \(outcome.connectionsFailed) failed"
            await refresh()
        } catch {
            statusMessage = "Sync failed: \(error)"
        }
    }

    public func loadSampleData() async {
        do { try await core.loadSampleData(); statusMessage = "Sample data loaded"; await refresh() }
        catch { statusMessage = "Sample load failed: \(error)" }
    }

    public func claim(token: String) async {
        do {
            try await core.claimSetupToken(token)
            statusMessage = "Connection added"
            await syncNow()
        } catch {
            statusMessage = "Claim failed: \(error)"
        }
    }

    public func setClass(accountId: String, to cls: AccountClass) async {
        try? await core.setAccountClass(accountId: accountId, accountClass: cls)
        await refresh()
    }

    private static func databasePath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("TrackTheMoney", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ttm.db").path
    }
}
