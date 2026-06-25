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
        } catch {
            statusMessage = "Load failed: \(error)"
        }
    }

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
