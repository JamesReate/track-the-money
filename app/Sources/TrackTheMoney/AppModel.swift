import Foundation
import Observation
import TTMCore

/// A selectable spending window (a month, or all time).
public struct SpendingPeriod: Identifiable, Equatable, Sendable {
    public let id: String        // "yyyy-MM" or "all"
    public let label: String     // "Jun", "May 25", "All time"
    public let from: UnixTime
    public let to: UnixTime
}

/// A validated backup awaiting the user's confirmation, held as a private copy
/// inside our container (the picker's security scope ends when it returns).
public struct PendingRestore: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let info: BackupInfo
    /// The picked file's name without extension — the default profile name.
    public var displayName: String = "Imported"
}

/// Observable view-model bridging SwiftUI to the `CoreFacade`. Owns one facade
/// instance; all screens read its published state and call its async actions.
@MainActor
@Observable
public final class AppModel {
    private let core: CoreFacade

    public var netWorth: NetWorthSummary?
    public var series: [NetWorthPoint] = []
    public var debtSeries: [DebtPoint] = []
    public var accounts: [AccountSummary] = []
    public var recentTransactions: [TransactionRecord] = []
    public var properties: [PropertySummary] = []
    public var interest: InterestRollup?
    public var categories: [CategorySummary] = []
    public var rules: [Rule] = []
    public var spending: [SpendingLine] = []
    public var spendingPeriods: [SpendingPeriod] = []
    public var selectedSpendingPeriod = ""
    public var statusMessage = ""
    public var isSyncing = false
    /// Transaction id just (re)categorized — drives the row glow highlight.
    public var lastCategorized: String?
    /// Transactions-tab state: the search box + the categorized/uncategorized chip.
    public var txnSearch = ""
    public var txnFilter: CategorizationFilter = .all
    public var uncategorizedCount = 0
    /// Transaction count per category id (for the Categories manager).
    public var categoryCounts: [String: Int] = [:]
    /// Snapshot written to temp, waiting for the system exporter to save it.
    public var pendingExport: URL?
    /// Validated backup awaiting confirmation in the restore sheet.
    public var pendingRestore: PendingRestore?
    /// A pre-restore copy exists, so "Undo last restore" is offered.
    public var canUndoRestore = false
    /// Every profile on this device, and the one whose data is on screen
    /// (docs/plans/PROFILES_PLAN.md).
    public var profiles: [ProfileSummary] = []
    public var activeProfile: ProfileSummary?
    /// The active profile's SimpleFIN connections and their state on this device.
    public var connections: [ConnectionSummary] = []
    /// A switch or profile creation is in flight — disables further switching.
    public var isSwitchingProfile = false

    /// What a new profile starts with.
    public enum ProfileSeed: String, CaseIterable, Identifiable, Sendable {
        case empty, demoBank, sampleData
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .empty:      return "Empty"
            case .demoBank:   return "SimpleFIN demo bank"
            case .sampleData: return "Sample data"
            }
        }
        /// Demo and sample profiles are test data by definition.
        public var suggestedKind: ProfileKind { self == .empty ? .real : .test }
        public var suggestedName: String {
            switch self {
            case .empty:      return ""
            case .demoBank:   return "SimpleFIN demo"
            case .sampleData: return "Sample data"
            }
        }
    }

    public init(core: CoreFacade) { self.core = core }

    /// Live model backed by SQLite in Application Support + Keychain + URLSession.
    /// One store per profile under `Application Support/TrackTheMoney/`.
    public static func live() throws -> AppModel {
        let core = try LocalCore(profilesRoot: try storeRoot(),
                                 secrets: KeychainSecretStore(),
                                 network: URLSessionNetworkClient(),
                                 onDeviceCategorizer: makeOnDeviceCategorizer())
        return AppModel(core: core)
    }

    /// Default to the best available on-device model (free tier). Apple's
    /// Foundation Models LLM when present, else the heuristic baseline. In
    /// production this is gated behind the one-time "local AI" unlock (StoreKit —
    /// TODO); the paid cloud tier swaps in the more capable Claude path.
    private static func makeOnDeviceCategorizer() -> OnDeviceCategorizer {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-noAI") { return NoOpOnDeviceCategorizer() }
        if args.contains("-stubAI") { return HeuristicOnDeviceCategorizer() }   // deterministic for tests
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), FoundationModelsCategorizer.isSupported {
            return FoundationModelsCategorizer()
        }
        #endif
        return HeuristicOnDeviceCategorizer()
    }

    public func refresh() async {
        canUndoRestore = await core.canUndoRestore()
        // Profiles are unavailable on a fixed-path core (previews); not an error.
        profiles = (try? await core.profiles()) ?? []
        activeProfile = profiles.first { $0.isActive }
        do {
            connections = try await core.connections()
            netWorth = try await core.netWorthSummary()
            series = try await core.netWorthSeries(from: nil, to: nil)
            debtSeries = try await core.debtSeries(from: nil, to: nil)
            accounts = try await core.accounts().filter { !$0.archived }
            categories = try await core.categories()
            categoryCounts = try await core.categoryTransactionCounts()
            try await reloadTransactions()
            properties = try await core.properties()
            interest = try await core.interestSummary(from: 0, to: 4_102_444_800) // through ~2100
            rules = try await core.rules()
            buildSpendingPeriods()
            let period = spendingPeriods.first { $0.id == selectedSpendingPeriod }
            spending = try await core.spending(from: period?.from ?? 0, to: period?.to ?? 4_102_444_800)
        } catch {
            statusMessage = "Load failed: \(error)"
        }
    }

    public func selectSpendingPeriod(_ id: String) async {
        selectedSpendingPeriod = id
        guard let p = spendingPeriods.first(where: { $0.id == id }) else { return }
        spending = (try? await core.spending(from: p.from, to: p.to)) ?? []
    }

    /// Last 6 months + All time. Defaults the selection to the current month.
    private func buildSpendingPeriods() {
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)
        func monthStart(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }

        let month = DateFormatter(); month.dateFormat = "MMM"
        let monthYr = DateFormatter(); monthYr.dateFormat = "MMM yy"
        let idFmt = DateFormatter(); idFmt.dateFormat = "yyyy-MM"

        var periods: [SpendingPeriod] = []
        for i in 0..<6 {
            guard let start = cal.date(byAdding: .month, value: -i, to: monthStart(now)),
                  let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) else { continue }
            let yr = cal.component(.year, from: start)
            periods.append(SpendingPeriod(
                id: idFmt.string(from: start),
                label: yr == currentYear ? month.string(from: start) : monthYr.string(from: start),
                from: Int64(start.timeIntervalSince1970), to: Int64(end.timeIntervalSince1970)))
        }
        periods.append(SpendingPeriod(id: "all", label: "All time", from: 0, to: 4_102_444_800))
        spendingPeriods = periods
        if !periods.contains(where: { $0.id == selectedSpendingPeriod }) {
            selectedSpendingPeriod = periods.first?.id ?? "all"   // current month
        }
    }

    public func categoryName(_ id: String?) -> String {
        guard let id else { return "Uncategorized" }
        return categories.first { $0.id == id }?.name ?? id
    }

    /// Stored "#RRGGBB" for a category (nil → the Uncategorized tone).
    public func categoryColorHex(_ id: String?) -> String? {
        let key = id ?? "uncategorized"
        return categories.first { $0.id == key }?.color
            ?? categories.first { $0.id == "uncategorized" }?.color
    }

    // MARK: Category tree (two levels: groups → leaves)

    /// A category that has children is a group header, not assignable.
    public func isGroup(_ id: String) -> Bool { categories.contains { $0.parentId == id } }

    public func children(of parentId: String) -> [CategorySummary] {
        categories.filter { $0.parentId == parentId }
    }

    /// Top-level expense groups (have children), in sort order.
    public var expenseGroups: [CategorySummary] {
        categories.filter { $0.parentId == nil && $0.kind == "expense" && isGroup($0.id) }
    }

    /// Top-level expense leaves with no group (standalone, assignable).
    public var standaloneExpenseLeaves: [CategorySummary] {
        categories.filter { $0.parentId == nil && $0.kind == "expense" && !isGroup($0.id) }
    }

    /// System categories (Income/Transfer/Interest/Uncategorized).
    public var systemCategories: [CategorySummary] {
        categories.filter { $0.isSystem }
    }

    // MARK: Categorization actions

    public func setCategory(transactionId: String, categoryId: String?) async {
        try? await core.setCategory(transactionId: transactionId, categoryId: categoryId)
        await refresh()
        lastCategorized = transactionId
    }

    /// Build a "description contains <payee>" rule → category, apply to past + future.
    public func createRule(fromText text: String, categoryId: String, highlight transactionId: String? = nil) async {
        let id = "rule-\(UUID().uuidString.prefix(8))"
        let rule = Rule(id: id, name: text, categoryId: categoryId, priority: 100, enabled: true,
                        condition: Condition(op: .and, clauses: [
                            Clause(field: .description, match: .contains, value: text)
                        ]))
        try? await core.upsertRule(rule, apply: .backfill)
        await refresh()
        lastCategorized = transactionId
    }

    // MARK: Category management actions

    /// Create a category (auto-colored). Returns its id, or nil on failure.
    @discardableResult
    public func createCategory(name: String, parentId: String?, kind: String = "expense") async -> String? {
        do {
            let made = try await core.createCategory(name: name, parentId: parentId, kind: kind, color: nil)
            await refresh()
            return made.id
        } catch {
            statusMessage = "Couldn’t create category: \(error)"
            return nil
        }
    }

    public func renameCategory(id: String, name: String) async {
        try? await core.renameCategory(id: id, name: name); await refresh()
    }

    public func recolorCategory(id: String, color: String) async {
        try? await core.recolorCategory(id: id, color: color); await refresh()
    }

    public func moveCategory(id: String, toParentId: String?) async {
        do { try await core.moveCategory(id: id, toParentId: toParentId); await refresh() }
        catch { statusMessage = "Couldn’t move: \(error)" }
    }

    public func reorderCategories(orderedIds: [String]) async {
        try? await core.reorderCategories(orderedIds: orderedIds); await refresh()
    }

    public func deleteCategory(id: String, reassignTo: String?) async {
        do { try await core.deleteCategory(id: id, reassignTo: reassignTo); await refresh() }
        catch { statusMessage = "Couldn’t delete: \(error)" }
    }

    public func mergeCategory(fromId: String, intoId: String) async {
        do { try await core.mergeCategory(fromId: fromId, intoId: intoId); await refresh() }
        catch { statusMessage = "Couldn’t merge: \(error)" }
    }

    /// Describes a leaf that just became a group while still holding transactions
    /// (CATEGORIZATION_PLAN.md §1 "graceful promotion").
    public struct PromotionPrompt: Equatable, Identifiable {
        public let id = UUID()
        public let parentId: String
        public let parentName: String
        public let newChildId: String
        public let newChildName: String
        public let txnCount: Int
    }

    /// Create a subcategory under `parentId`. If the parent was a leaf that already
    /// holds transactions, it has just been promoted to a group header — return a
    /// prompt so the UI can offer to move those (now stranded) transactions.
    public func createSubcategory(name: String, parentId: String) async -> PromotionPrompt? {
        let wasLeaf = !isGroup(parentId)
        let directTxns = categoryCounts[parentId] ?? 0
        guard let newId = await createCategory(name: name, parentId: parentId) else { return nil }
        guard wasLeaf, directTxns > 0 else { return nil }
        return PromotionPrompt(parentId: parentId, parentName: categoryName(parentId),
                               newChildId: newId, newChildName: name, txnCount: directTxns)
    }

    /// Move a category's transactions + rules into another (both kept).
    public func moveCategoryTransactions(fromId: String, toId: String) async {
        do { try await core.reassignCategoryContents(fromId: fromId, toId: toId); await refresh() }
        catch { statusMessage = "Couldn’t move transactions: \(error)" }
    }

    /// Create (or reuse) a "General" subcategory under `parentId` and move the
    /// parent's transactions into it.
    public func moveToNewGeneral(parentId: String) async {
        let existing = children(of: parentId).first { $0.name.caseInsensitiveCompare("General") == .orderedSame }
        let generalId: String?
        if let existing { generalId = existing.id }
        else { generalId = await createCategory(name: "General", parentId: parentId) }
        guard let gid = generalId else { return }
        await moveCategoryTransactions(fromId: parentId, toId: gid)
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

    /// Reload the Transactions feed honoring the current search text + filter chip,
    /// and refresh the uncategorized badge count.
    public func reloadTransactions() async throws {
        let text = txnSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = TxnQuery(categorization: txnFilter,
                             searchText: text.isEmpty ? nil : text,
                             limit: text.isEmpty ? 100 : 200)
        recentTransactions = try await core.transactions(query)
        uncategorizedCount = try await core.uncategorizedCount()
    }

    public func search(_ text: String) async {
        txnSearch = text
        try? await reloadTransactions()
    }

    public func setTxnFilter(_ filter: CategorizationFilter) async {
        txnFilter = filter
        try? await reloadTransactions()
    }

    /// The full uncategorized queue for guided Review (separate from the tab feed).
    public func fetchUncategorized() async -> [TransactionRecord] {
        (try? await core.transactions(TxnQuery(categorization: .uncategorized, limit: 500))) ?? []
    }

    /// Free on-device AI suggestion for one transaction (nil if no model / declines).
    public func suggestCategory(for transactionId: String) async -> CategorySuggestion? {
        try? await core.suggestCategory(transactionId: transactionId)
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
            connections = (try? await core.connections()) ?? connections
        }
    }

    /// Re-link an existing connection with a fresh setup token, keeping its
    /// accounts and history (PROFILES_PLAN §4.7).
    public func reconnect(connectionId: String, token: String) async {
        do {
            try await core.reconnect(connectionId: connectionId, setupToken: token)
            statusMessage = "Connection re-linked"
            await syncNow()
        } catch {
            statusMessage = "Reconnect failed: \(error)"
        }
    }

    /// Connections sync can actually reach (sample rows have no credential).
    public var hasSyncableConnection: Bool { connections.contains { $0.state != .sample } }

    // MARK: Profiles (docs/plans/PROFILES_PLAN.md)

    public func switchProfile(to id: String) async {
        guard !isSyncing, !isSwitchingProfile, id != activeProfile?.id else { return }
        isSwitchingProfile = true
        defer { isSwitchingProfile = false }
        do {
            try await core.switchProfile(id: id)
            resetPerProfileViewState()
            await refresh()
            statusMessage = ""
        } catch {
            statusMessage = "Couldn’t switch profile: \(Self.message(error))"
        }
    }

    /// Create a profile, switch to it, and fill it per `seed`. The demo bank
    /// claims SimpleFIN's public demo token over the network and syncs.
    public func createProfile(name: String, kind: ProfileKind, seed: ProfileSeed) async {
        guard !isSyncing, !isSwitchingProfile else { return }
        let made: ProfileSummary
        do { made = try await core.createProfile(name: name, kind: kind) }
        catch { statusMessage = "Couldn’t create profile: \(Self.message(error))"; return }
        await switchProfile(to: made.id)
        guard activeProfile?.id == made.id else { return }
        switch seed {
        case .empty:
            statusMessage = "Created “\(made.name)”. Add a SimpleFIN connection to start syncing."
        case .sampleData:
            await loadSampleData()
        case .demoBank:
            await claim(token: SimpleFINDemo.setupToken)
        }
    }

    public func renameProfile(id: String, to name: String) async {
        do { try await core.renameProfile(id: id, name: name); await refreshProfiles() }
        catch { statusMessage = Self.message(error) }
    }

    public func setProfileKind(id: String, to kind: ProfileKind) async {
        do { try await core.setProfileKind(id: id, kind: kind); await refreshProfiles() }
        catch { statusMessage = Self.message(error) }
    }

    public func deleteProfile(id: String) async {
        let name = profiles.first { $0.id == id }?.name ?? "Profile"
        do {
            try await core.deleteProfile(id: id)
            await refreshProfiles()
            statusMessage = "Deleted “\(name)”."
        } catch {
            statusMessage = Self.message(error)
        }
    }

    /// `-profile <name>`: open that profile at launch, creating it if needed.
    public func applyLaunchProfile(named name: String) async {
        let all = (try? await core.profiles()) ?? []
        if let match = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            await switchProfile(to: match.id)
        } else if let made = try? await core.createProfile(name: name, kind: .test) {
            await switchProfile(to: made.id)
        }
    }

    private func refreshProfiles() async {
        profiles = (try? await core.profiles()) ?? profiles
        activeProfile = profiles.first { $0.isActive }
    }

    /// Search text, filters and highlights belong to the profile being left.
    private func resetPerProfileViewState() {
        txnSearch = ""
        txnFilter = .all
        lastCategorized = nil
        selectedSpendingPeriod = ""
        pendingRestore.map { try? FileManager.default.removeItem(at: $0.url) }
        pendingRestore = nil
    }

    public func setClass(accountId: String, to cls: AccountClass) async {
        try? await core.setAccountClass(accountId: accountId, accountClass: cls)
        await refresh()
    }

    /// Rename an account for display only (nil/empty reverts to the bank name).
    public func rename(accountId: String, to name: String?) async {
        try? await core.renameAccount(accountId: accountId, name: name)
        await refresh()
    }

    // MARK: Backup & restore (docs/plans/DATA_PORTABILITY_PLAN.md)

    /// Snapshot the store to a temp file for the system exporter to write out.
    public func startExport() async {
        do { pendingExport = try await core.exportBackup() }
        catch { statusMessage = Self.message(error) }
    }

    /// Clean up the temp snapshot once the exporter is done with it — on
    /// cancellation too, so nothing is left behind in the temp directory.
    public func finishExport(_ result: Result<URL, Error>) {
        if let url = pendingExport { try? FileManager.default.removeItem(at: url) }
        pendingExport = nil
        switch result {
        case .success(let saved):
            statusMessage = "Backup saved as \(saved.lastPathComponent)"
        case .failure(let error):
            let cancelled = (error as NSError).code == NSUserCancelledError
            statusMessage = cancelled ? "" : "Backup failed: \(Self.message(error))"
        }
    }

    /// Copy the picked file into our container, validate it, and hold it for
    /// confirmation. Nothing about the live store is touched here.
    public func prepareRestore(from picked: URL) async {
        let fm = FileManager.default
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let temp = fm.temporaryDirectory
            .appendingPathComponent("ttm-restore-\(UUID().uuidString).\(BackupManager.fileExtension)")
        do {
            try fm.copyItem(at: picked, to: temp)
            pendingRestore = PendingRestore(url: temp, info: try await core.inspectBackup(at: temp),
                                            displayName: picked.deletingPathExtension().lastPathComponent)
        } catch {
            try? fm.removeItem(at: temp)
            statusMessage = Self.message(error)
        }
    }

    public func cancelRestore() {
        if let pending = pendingRestore { try? FileManager.default.removeItem(at: pending.url) }
        pendingRestore = nil
    }

    /// Replace everything with the confirmed backup, then reload every screen.
    public func confirmRestore() async {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        defer { try? FileManager.default.removeItem(at: pending.url) }
        do {
            let info = try await core.restoreBackup(from: pending.url)
            canUndoRestore = await core.canUndoRestore()
            await refresh()
            statusMessage = "Restored \(info.transactions) transactions." + reconnectHint
        } catch {
            statusMessage = Self.message(error)
        }
    }

    /// Load the confirmed backup as a new profile and switch to it. The
    /// current profile is untouched.
    public func openPendingAsProfile(name: String, kind: ProfileKind) async {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        defer { try? FileManager.default.removeItem(at: pending.url) }
        do {
            let made = try await core.importProfile(from: pending.url, name: name, kind: kind)
            await switchProfile(to: made.id)
            statusMessage = "Opened “\(made.name)” with \(pending.info.transactions) transactions." + reconnectHint
        } catch {
            statusMessage = Self.message(error)
        }
    }

    /// Secrets live in the Keychain, never the backup — so a file from another
    /// device brings the data but not a working connection. Say so only when
    /// that's actually the case.
    private var reconnectHint: String {
        connections.contains { $0.state == .missingCredential }
            ? " Its SimpleFIN connection isn’t linked on this device — reconnect it in Settings to resume syncing."
            : ""
    }

    public func undoRestore() async {
        do {
            try await core.undoRestore()
            canUndoRestore = await core.canUndoRestore()
            await refresh()
            statusMessage = "Restore undone — your previous data is back."
        } catch {
            statusMessage = Self.message(error)
        }
    }

    /// BackupError and friends carry user-facing copy; anything else falls back
    /// to the raw description.
    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `Application Support/TrackTheMoney/` — holds `profiles.json` and one
    /// folder per profile (and, on a pre-profiles install, the legacy `ttm.db`
    /// that LocalCore adopts on first launch).
    private static func storeRoot() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("TrackTheMoney", isDirectory: true)
        // UI tests pass -resetStore so each launch starts clean (the app
        // container persists across launches in one test run otherwise). Wipes
        // every profile, the registry, and any legacy store. Keychain items are
        // left alone; unreferenced ones are inert.
        if ProcessInfo.processInfo.arguments.contains("-resetStore") {
            try? fm.removeItem(at: base)
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
