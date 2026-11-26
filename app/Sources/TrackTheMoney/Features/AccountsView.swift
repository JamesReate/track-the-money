import SwiftUI
import TTMCore

// Accounts: classify, rename, delete; add and update manually tracked accounts
// (docs/plans/ACCOUNT_MANAGEMENT_PLAN.md).

struct AccountsView: View {
    @Bindable var model: AppModel
    @State private var renaming: AccountSummary?
    @State private var updating: AccountSummary?
    @State private var deleting: AccountSummary?
    @State private var settingRate: AccountSummary?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(accounts(.active)) { account in row(account) }
                }
                if !accounts(.paused).isEmpty {
                    Section {
                        ForEach(accounts(.paused)) { account in row(account) }
                    } header: { Eyebrow("Paused") }
                    footer: {
                        Text("Not syncing. Each still counts at its last balance. Resuming catches up from where it stopped.")
                    }
                }
                if !accounts(.excluded).isEmpty {
                    Section {
                        ForEach(accounts(.excluded)) { account in row(account) }
                    } header: { Eyebrow("Excluded from totals") }
                    footer: {
                        Text("Still syncing, but left out of net worth, the charts, spending and interest, and their transactions are hidden everywhere. Include one again to bring it all back.")
                    }
                }
                if !model.deletedAccounts.isEmpty {
                    Section {
                        ForEach(model.deletedAccounts) { account in
                            HStack {
                                Text(account.name).foregroundStyle(Brand.slate).lineLimit(1)
                                Spacer()
                                Button("Sync again") { Task { await model.restoreAccount(account) } }
                                    .font(.callout)
                            }
                            .listRowBackground(Brand.surface)
                        }
                    } header: { Eyebrow("Deleted bank accounts") }
                    footer: {
                        Text("Still shared by SimpleFIN Bridge, so they’re kept hidden instead of syncing back. “Sync again” brings one back with its recent history on the next sync. To stop sharing one, remove it in SimpleFIN Bridge.")
                    }
                }
            }
            .statementBackground()
            .inlineNavTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add manual account", systemImage: "plus") }
                        .accessibilityIdentifier("addManualAccount")
                }
            }
            .sheet(item: $renaming) { account in RenameAccountSheet(model: model, account: account) }
            .sheet(item: $updating) { account in ManualValueSheet(model: model, account: account) }
            .sheet(isPresented: $adding) { AddManualAccountSheet(model: model) }
            .sheet(item: $settingRate) { account in InterestRateSheet(model: model, account: account) }
            .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible,
                                presenting: deleting) { account in
                Button("Delete", role: .destructive) { Task { await model.deleteAccount(account) } }
                Button("Cancel", role: .cancel) {}
            } message: { account in Text(deleteMessage(account)) }
            .overlay {
                if model.accounts.isEmpty && model.deletedAccounts.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts", systemImage: "building.columns")
                    } description: {
                        Text("Add a SimpleFIN connection in Settings, or track an account by hand.")
                    } actions: {
                        Button("Add manual account") { adding = true }
                    }
                }
            }
        }
    }

    private func row(_ account: AccountSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Brand.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Menu {
                        Picker("Class", selection: classBinding(account)) {
                            ForEach(AccountClass.allCases, id: \.self) { cls in
                                Text(cls.label).tag(cls)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(dot(account.accountClass)).frame(width: 6, height: 6)
                            Text(account.accountClass.label.uppercased())
                                .font(.system(.caption2).weight(.semibold)).tracking(0.8)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Brand.slate)
                    }
                    if let promo = account.activePromo {
                        Text("\(APR.format(promo.aprBps)) until \(APR.day(promo.endsOn))")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Brand.brass)
                    } else if account.accountClass.isDebt, let apr = account.aprBps {
                        Text("\(APR.format(apr)) APR").font(.caption2.weight(.semibold)).foregroundStyle(Brand.clay)
                    }
                    if account.status == .paused {
                        Text(pausedLabel(account)).font(.caption2).foregroundStyle(Brand.slate)
                    } else if account.source == .manual {
                        Text(updatedLabel(account)).font(.caption2).foregroundStyle(Brand.slate)
                    }
                }
            }
            Spacer()
            MoneyText(account.balance, size: 17,
                      color: account.status == .excluded ? Brand.slate
                        : account.accountClass.contribution == .liability ? Brand.clay : Brand.evergreen,
                      currency: account.currency)
        }
        .opacity(account.status == .excluded ? 0.7 : 1)
        .padding(.vertical, 4)
        .listRowBackground(Brand.surface)
        .contentShape(Rectangle())
        .onTapGesture { if account.source == .manual { updating = account } }
        .accessibilityIdentifier("account-\(account.name)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { renaming = account } label: { Label("Rename", systemImage: "pencil") }
                .tint(Brand.brass)
            if account.source == .manual {
                Button { updating = account } label: { Label("Update value", systemImage: "square.and.pencil") }
                    .tint(Brand.evergreen)
            }
            if account.accountClass.isDebt {
                Button { settingRate = account } label: { Label("Interest rate", systemImage: "percent") }
                    .tint(Brand.clay)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = account } label: { Label("Delete", systemImage: "trash") }
            excludeButton(account).tint(Brand.slate)
            if account.source == .synced { pauseButton(account).tint(Brand.brass) }
        }
        .contextMenu {
            if account.source == .manual {
                Button { updating = account } label: { Label("Update value…", systemImage: "square.and.pencil") }
            }
            if account.accountClass.isDebt {
                Button { settingRate = account } label: { Label("Interest rate…", systemImage: "percent") }
            }
            Button { renaming = account } label: { Label("Rename…", systemImage: "pencil") }
            Divider()
            excludeButton(account)
            if account.source == .synced { pauseButton(account) }
            Divider()
            Button(role: .destructive) { deleting = account } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private func accounts(_ status: AccountStatus) -> [AccountSummary] {
        model.accounts.filter { $0.status == status }
    }

    @ViewBuilder private func excludeButton(_ account: AccountSummary) -> some View {
        if account.status == .excluded {
            Button { Task { await model.setStatus(account, to: .active) } } label: {
                Label("Include in totals", systemImage: "plus.circle")
            }
        } else {
            Button { Task { await model.setStatus(account, to: .excluded) } } label: {
                Label("Exclude from totals", systemImage: "minus.circle")
            }
        }
    }

    @ViewBuilder private func pauseButton(_ account: AccountSummary) -> some View {
        if account.status == .paused {
            Button { Task { await model.setStatus(account, to: .active) } } label: {
                Label("Resume syncing", systemImage: "play.circle")
            }
        } else {
            Button { Task { await model.setStatus(account, to: .paused) } } label: {
                Label("Pause syncing", systemImage: "pause.circle")
            }
        }
    }

    private func pausedLabel(_ account: AccountSummary) -> String {
        guard let t = account.balanceDate else { return "Paused" }
        return "Paused · \(Time.date(t).formatted(date: .abbreviated, time: .omitted))"
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String { "Delete “\(deleting?.name ?? "")”?" }

    private func deleteMessage(_ account: AccountSummary) -> String {
        switch account.source {
        case .manual:
            return "Its value history goes with it. This can’t be undone."
        case .sample:
            return "Removes this sample account and its transactions."
        case .synced:
            return "Removes its transactions and balance history from this device. It stays hidden so syncing doesn’t bring it back — to stop sharing it, remove it in SimpleFIN Bridge."
        }
    }

    private func updatedLabel(_ account: AccountSummary) -> String {
        guard let t = account.balanceDate else { return "Manual" }
        return "Updated \(Time.date(t).formatted(date: .abbreviated, time: .omitted))"
    }

    private func classBinding(_ account: AccountSummary) -> Binding<AccountClass> {
        Binding(
            get: { account.accountClass },
            set: { newValue in Task { await model.setClass(accountId: account.id, to: newValue) } }
        )
    }

    private func dot(_ cls: AccountClass) -> Color {
        switch cls.contribution {
        case .asset: return Brand.evergreen
        case .liability: return Brand.clay
        case .ignored: return Brand.slate
        }
    }
}

extension AccountClass {
    var label: String {
        switch self {
        case .liquid: return "Liquid"
        case .investment: return "Investment"
        case .securedDebt: return "Secured debt"
        case .creditCard: return "Credit card"
        case .unsecuredDebt: return "Unsecured debt"
        case .realEstate: return "Real estate"
        case .income: return "Income"
        case .unclassified: return "Unclassified"
        }
    }

    /// What a manually tracked account can be: something with a balance.
    static var manualChoices: [AccountClass] { allCases.filter { $0.contribution != .ignored } }
}

extension Money {
    /// Lenient parse of a typed amount: "$12,345.67", "12345", " -40 ".
    init?(userInput: String) {
        let cleaned = userInput.filter { !$0.isWhitespace && $0 != "," && $0 != "$" }
        guard !cleaned.isEmpty else { return nil }
        self.init(decimalString: cleaned)
    }
}

/// APRs are basis points in the engine (2299 = 22.99%); people type percents.
enum APR {
    static func format(_ bps: Int) -> String {
        let percent = Decimal(bps) / 100
        return percent.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    /// "22.99", "22.99%", " 7 " → basis points, rounded to the nearest 0.01%.
    static func bps(fromPercent text: String) -> Int? {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "%" }
        guard !cleaned.isEmpty,
              var value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        value *= 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .bankers)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// A promo end day ("Mar 1, 2027"); `endsOn` is the start of a local day.
    static func day(_ t: UnixTime) -> String {
        Time.date(t).formatted(date: .abbreviated, time: .omitted)
    }
}

extension AccountSummary {
    /// The credit-card promo that applies right now, if any.
    var activePromo: PromoRate? {
        guard let promo, promo.isActive(at: Time.unix(Date())) else { return nil }
        return promo
    }
}

/// Set the current interest rate on a debt account. Sync never reports rates,
/// so this is the only source, and syncing leaves it alone.
struct InterestRateSheet: View {
    @Bindable var model: AppModel
    let account: AccountSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasPromo = false
    @State private var promoText = "0"
    @State private var promoEnds = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var error: String?

    private var isCard: Bool { account.accountClass == .creditCard }
    private var regularEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    /// A card may leave the regular rate blank while setting a promo, or while
    /// removing the one it has (otherwise a promo-only card could never drop
    /// its promo). Anything else needs a rate.
    private var canSave: Bool {
        let regularOK = regularEmpty ? (isCard && (hasPromo || account.promo != nil)) : APR.bps(fromPercent: text) != nil
        let promoOK = !hasPromo || APR.bps(fromPercent: promoText) != nil
        return regularOK && promoOK
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("e.g. 22.99", text: $text)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .accessibilityIdentifier("aprField")
                        Text("% APR").foregroundStyle(Brand.slate)
                    }
                } header: { Eyebrow(isCard ? "Regular rate" : "Interest rate") }
                footer: { Text("The rate on your latest statement. Update it when it changes.") }
                if isCard { promotion }
                if account.aprBps != nil {
                    Button("Remove regular rate", role: .destructive) {
                        Task {
                            error = await model.setAPR(accountId: account.id, aprBps: nil)
                            if error == nil { dismiss() }
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.clay)
                }
            }
            .statementBackground()
            .inlineNavTitle(account.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("aprSave")
                }
            }
            .onAppear {
                // Decimal's description is locale-independent ("22.99"), matching the parser.
                if let bps = account.aprBps { text = "\(Decimal(bps) / 100)" }
                if let promo = account.activePromo {
                    hasPromo = true
                    promoText = "\(Decimal(promo.aprBps) / 100)"
                    promoEnds = Time.date(promo.endsOn)
                }
            }
        }
    }

    @ViewBuilder private var promotion: some View {
        Section {
            Toggle("Promotional rate", isOn: $hasPromo)
                .tint(Brand.evergreen)
                .accessibilityIdentifier("promoToggle")
            if hasPromo {
                HStack {
                    TextField("e.g. 0", text: $promoText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityIdentifier("promoField")
                    Text("% APR").foregroundStyle(Brand.slate)
                }
                DatePicker("Ends", selection: $promoEnds, in: Calendar.current.startOfDay(for: Date())...,
                           displayedComponents: .date)
                    .accessibilityIdentifier("promoEnds")
            }
        } header: { Eyebrow("Promotion") }
        footer: {
            if let ended = account.promo, account.activePromo == nil {
                Text("The last promo (\(APR.format(ended.aprBps))) ended \(APR.day(ended.endsOn)). The regular rate applies now.")
            } else {
                Text("An intro or balance-transfer rate. It applies through the end date, then the regular rate takes over. Debt & Interest shows whether your cash can pay it off in time.")
            }
        }
    }

    private func save() {
        Task {
            let regular = regularEmpty ? nil : APR.bps(fromPercent: text)
            error = await model.setAPR(accountId: account.id, aprBps: regular)
            if error == nil, isCard {
                error = await model.setPromo(accountId: account.id,
                                             aprBps: hasPromo ? APR.bps(fromPercent: promoText) : nil,
                                             endsOn: hasPromo ? promoEnds : nil)
            }
            if error == nil { dismiss() }
        }
    }
}

/// Rename an account for display only. The account id is unchanged, so syncing
/// with SimpleFIN continues unaffected.
private struct RenameAccountSheet: View {
    @Bindable var model: AppModel
    let account: AccountSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Account name", text: $text)
                } header: { Eyebrow("Display name") }
                footer: {
                    if account.source == .synced {
                        Text("Syncs as “\(account.syncedName)”. Renaming is local and won’t affect syncing.")
                    }
                }
                if account.isRenamed {
                    Button("Reset to bank name", role: .destructive) {
                        Task { await model.rename(accountId: account.id, to: nil); dismiss() }
                    }
                }
            }
            .inlineNavTitle("Rename Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.rename(accountId: account.id, to: text); dismiss() }
                    }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { text = account.name }
        }
    }
}

/// Shared value + as-of fields for adding and updating a manual account.
private struct ValueFields: View {
    @Binding var value: String
    @Binding var asOf: Date
    let isDebt: Bool

    var body: some View {
        TextField(isDebt ? "Amount owed" : "Current value", text: $value)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .accessibilityIdentifier("manualValue")
        DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: .date)
    }
}

private struct AddManualAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountClass: AccountClass = .liquid
    @State private var value = ""
    @State private var asOf = Date()
    @State private var apr = ""
    @State private var error: String?
    @State private var saving = false

    private var isDebt: Bool { accountClass.isDebt }
    /// Blank is fine (no rate); anything typed must parse.
    private var aprBps: Int?? {
        apr.trimmingCharacters(in: .whitespaces).isEmpty ? .some(nil) : APR.bps(fromPercent: apr).map { .some($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. 401(k), Car, Cash)", text: $name)
                        .accessibilityIdentifier("manualName")
                    Picker("Type", selection: $accountClass) {
                        ForEach(AccountClass.manualChoices, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: { Eyebrow("Account") }
                Section {
                    ValueFields(value: $value, asOf: $asOf, isDebt: isDebt)
                    if isDebt {
                        HStack {
                            TextField("Interest rate (optional)", text: $apr)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text("% APR").foregroundStyle(Brand.slate)
                        }
                    }
                } header: { Eyebrow("Value") }
                footer: {
                    Text(isDebt
                         ? "Enter what you owe as a positive amount. Update it whenever you check the balance."
                         : "Update it whenever you check the balance — each update is kept for the net-worth chart.")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.clay)
                }
            }
            .statementBackground()
            .inlineNavTitle("Add Manual Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let money = Money(userInput: value), let rate = aprBps else { return }
                        saving = true
                        Task {
                            error = await model.addManualAccount(name: name, accountClass: accountClass,
                                                                 balance: money, asOf: asOf,
                                                                 aprBps: isDebt ? rate : nil)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || Money(userInput: value) == nil || (isDebt && aprBps == nil))
                    .accessibilityIdentifier("manualSave")
                }
            }
        }
    }
}

/// Record a new value for a manual account and review (or prune) its history.
private struct ManualValueSheet: View {
    @Bindable var model: AppModel
    let account: AccountSummary
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var asOf = Date()
    @State private var history: [BalanceEntry] = []
    @State private var error: String?
    @State private var saving = false

    private var isDebt: Bool { account.accountClass.contribution == .liability }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ValueFields(value: $value, asOf: $asOf, isDebt: isDebt)
                } header: { Eyebrow("New value") }
                footer: { Text("A value for a day that already has one replaces it.") }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.clay)
                }
                Section {
                    ForEach(history) { entry in
                        HStack {
                            Text(Time.date(entry.asOf).formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(Brand.ink)
                            Spacer()
                            MoneyText(entry.balance, size: 15, color: isDebt ? Brand.clay : Brand.evergreen,
                                      currency: account.currency)
                        }
                        .swipeActions {
                            Button(role: .destructive) { remove(entry) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { remove(entry) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: { Eyebrow("History") }
            }
            .statementBackground()
            .inlineNavTitle(account.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let money = Money(userInput: value) else { return }
                        saving = true
                        Task {
                            error = await model.setManualBalance(accountId: account.id, balance: money, asOf: asOf)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving || Money(userInput: value) == nil)
                    .accessibilityIdentifier("manualSave")
                }
            }
            .task { history = await model.balanceHistory(accountId: account.id) }
        }
    }

    private func remove(_ entry: BalanceEntry) {
        Task {
            error = await model.deleteBalanceEntry(accountId: account.id, asOf: entry.asOf)
            history = await model.balanceHistory(accountId: account.id)
        }
    }
}
