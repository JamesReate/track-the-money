import SwiftUI
import TTMCore

// Sheets for the monthly budget (MONTHLY_BUDGET_PLAN.md D2, D6).

/// "Can I afford it?": an amount and what it's for, answered live from the
/// month's numbers. Save it as a maybe (tentative) or plan it (confirmed).
struct AffordSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "300"
    @State private var categoryId: String?
    @State private var label = ""

    private var amount: Money { Money(typed: amountText) ?? .zero }
    private static let presets: [Int64] = [100, 300, 800, 2_500]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let b = model.budget {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Splurge room this month: **\(max(.zero, b.splurgeRoom).dollars)**")
                            .font(.subheadline).foregroundStyle(Brand.slate)
                        amountField
                        forPicker(b)
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("What is it? (optional)")
                            TextField("A gift, concert tickets, a trip…", text: $label)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("afford-label")
                        }
                        if amount.cents > 0 { verdict(b) }
                        buttons
                    }
                    .padding(20)
                }
            }
            .statementBackground()
            .inlineNavTitle("Can I afford it?")
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 680)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("afford-done") }
            }
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("How much")
            HStack(spacing: 4) {
                Text("$").font(.serif(36)).foregroundStyle(Brand.slate)
                TextField("0", text: $amountText)
                    .font(.serif(36))
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .accessibilityIdentifier("afford-amount")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { dollars in
                    let on = amount.cents == dollars * 100
                    Button(Money(cents: dollars * 100).dollars) { amountText = "\(dollars)" }
                        .buttonStyle(.bordered)
                        .tint(on ? Brand.evergreen : Brand.slate)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("afford-preset-\(dollars)")
                }
            }
        }
    }

    private func forPicker(_ b: BudgetMonth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("For")
            Picker("For", selection: $categoryId) {
                Text("Nothing in particular").tag(String?.none)
                ForEach(b.rows.filter { !$0.isEverythingElse }) { row in
                    Text("\(row.name) · \(max(.zero, row.left - row.reserved).dollars) left").tag(Optional(row.id))
                }
            }
            .pickerStyle(.menu)
            .tint(Brand.evergreen)
            .accessibilityIdentifier("afford-category")
        }
    }

    private func verdict(_ b: BudgetMonth) -> some View {
        let check = b.afford(amount, categoryId: categoryId)
        let (title, fg, bg): (String, Color, Color) = switch check.verdict {
        case .yes: ("Yes, go for it", Brand.evergreen, Color(hex: 0xE4EEE8))
        case .trimSavings: ("Only by trimming savings", Color(hex: 0x6B5223), Color(hex: 0xF3EEDF))
        case .notThisMonth: ("Not this month", Color(hex: 0x8F3F2C), Color(hex: 0xF5E6E0))
        }
        let text: String
        switch check.verdict {
        case .yes:
            let fromPlan = check.fromCategory.cents > 0 ? "\(check.fromCategory.dollars) comes out of \(check.rowName ?? "its")'s plan"
                + (check.fromRoom.cents > 0 ? " and \(check.fromRoom.dollars) from splurge room. " : ". ") : ""
            text = fromPlan + "You'd still have \(check.roomAfter.dollars) of splurge room this month."
        case .trimSavings:
            text = "It's \(check.fromSavings.dollars) more than your splurge room. Skipping that much of this month's \(b.savingsGoal.dollars) savings would cover it; bills and category plans stay intact."
        case .notThisMonth:
            let over = amount - check.fromCategory - check.fromRoom
            let half = Money(cents: (amount.cents + 1) / 2)
            let fits = b.afford(half, categoryId: categoryId).verdict == .yes
            text = "It's \(over.dollars) more than your splurge room" + (b.savingsGoal.cents > 0 ? ", even skipping this month's savings. " : ". ")
                + (fits ? "Split over two months it's \(half.dollars) a month, which fits." : "Worth planning across a few months.")
        }
        let parts: [MonthBar.Part] = [
            .init(id: "plan", label: "\(check.rowName ?? "Category") plan", amount: check.fromCategory, color: Color(hex: 0x586E5A)),
            .init(id: "room", label: "Splurge room", amount: check.fromRoom, color: Brand.evergreen),
            .init(id: "savings", label: "Savings", amount: check.fromSavings, color: Brand.brass),
            .init(id: "short", label: "Short", amount: check.short, color: Brand.clay),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.serif(26)).foregroundStyle(fg).accessibilityIdentifier("afford-verdict")
            Text(text).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            MonthBar(parts: parts).padding(.top, 4)
            Text("Paid from: " + parts.filter { $0.amount.cents > 0 }.map { "\($0.label.lowercased()) \($0.amount.dollars)" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Brand.slate)
        }
        .padding(18)
        .background(bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                save(.confirmed)
            } label: {
                Text("Plan it this month").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Brand.evergreen)
            .disabled(amount.cents == 0)
            .accessibilityIdentifier("afford-plan")
            HStack(spacing: 10) {
                Button { dismiss() } label: { Text("Just checking").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.bordered).tint(Brand.slate)
                    .accessibilityIdentifier("afford-just-checking")
                Button { save(.tentative) } label: { Text("Save as a maybe").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.bordered).tint(Brand.evergreen)
                    .disabled(amount.cents == 0)
                    .accessibilityIdentifier("afford-maybe")
            }
            Text("A maybe is listed but doesn't count yet. Planned purchases come out of splurge room now, until you mark them bought.")
                .font(.caption).foregroundStyle(Brand.slate)
        }
    }

    private func save(_ status: PlannedPurchase.Status) {
        let name = label.trimmingCharacters(in: .whitespaces)
        let fallback = categoryId.flatMap { id in model.budget?.rows.first { $0.id == id }?.name } ?? "Purchase"
        Task {
            await model.savePurchase(label: name.isEmpty ? fallback : name, amount: amount, categoryId: categoryId, status: status)
            dismiss()
        }
    }
}

/// The monthly savings goal: comes off the top, like a bill.
struct SavingsGoalSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $text)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityIdentifier("savings-field")
                } header: { Eyebrow("Set aside each month") }
                footer: { Text("It comes off the top, before category plans. Trimming it is the last resort in \"Can I afford it?\".") }
            }
            .formStyle(.grouped)
            .statementBackground()
            .inlineNavTitle("Savings goal")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 200)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let goal = Money(typed: text.isEmpty ? "0" : text) else { return }
                        Task { await model.setSavingsGoal(goal); dismiss() }
                    }
                    .disabled(Money(typed: text.isEmpty ? "0" : text) == nil)
                    .accessibilityIdentifier("savings-save")
                }
            }
            .onAppear { text = model.budget?.savingsGoal.fieldText ?? "0" }
        }
    }
}

/// How each payer counts: regular (salary), variable (contract work) or not
/// budgeted (one-offs).
struct IncomeSourcesSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var modes: [String: IncomeMode] = [:]
    @State private var estimates: [String: String] = [:]

    private var sources: [IncomeSourceMonth] { model.budget?.income.sources ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                if sources.isEmpty {
                    Section { Text("Nothing categorized as Income in the last three months.").foregroundStyle(Brand.slate) }
                }
                ForEach(sources) { source in
                    Section {
                        Picker("Counts as", selection: Binding(get: { modes[source.key] ?? source.mode },
                                                               set: { modes[source.key] = $0 })) {
                            if source.isSteady { Text("Regular: expected paychecks").tag(IncomeMode.regular) }
                            Text("Variable: a cautious estimate").tag(IncomeMode.variable)
                            Text("Not budgeted: only once it lands").tag(IncomeMode.notBudgeted)
                        }
                        .accessibilityIdentifier("income-mode-\(source.name)")
                        if (modes[source.key] ?? source.mode) == .variable {
                            TextField("Lowest recent month, \(source.lowestMonth.dollars)",
                                      text: Binding(get: { estimates[source.key] ?? "" }, set: { estimates[source.key] = $0 }))
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .accessibilityIdentifier("income-estimate-\(source.name)")
                        }
                        if source.isUserSet {
                            Button("Use the default") {
                                Task { await model.setIncomeMode(source, mode: nil, estimate: nil); load() }
                            }
                        }
                    } header: { Eyebrow(source.name) }
                    footer: {
                        Text("Typical month \(source.typicalMonth.dollars) · lowest \(source.lowestMonth.dollars)"
                             + (source.isSteady ? " · steady pay found" : ""))
                    }
                }
            }
            .formStyle(.grouped)
            .statementBackground()
            .inlineNavTitle("Income sources")
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(); dismiss() } }.accessibilityIdentifier("income-save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        modes = [:]
        estimates = Dictionary(sources.filter { $0.isUserSet && $0.mode == .variable && $0.estimate != $0.lowestMonth }
            .map { ($0.key, $0.estimate.fieldText) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() async {
        for source in sources {
            let mode = modes[source.key] ?? source.mode
            let typed = estimates[source.key].flatMap { Money(typed: $0) }
            let changedMode = mode != source.mode
            let changedEstimate = mode == .variable && typed != nil && typed != source.estimate
            guard changedMode || changedEstimate else { continue }
            await model.setIncomeMode(source, mode: mode, estimate: mode == .variable ? typed : nil)
        }
    }
}

/// Mark a planned purchase bought, linked to the charge when there is one.
struct MarkBoughtSheet: View {
    @Bindable var model: AppModel
    let purchase: PlannedPurchase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let matches = model.budget?.matches(for: purchase) ?? []
                Section {
                    if matches.isEmpty {
                        Text("No charge this month within 20% of \(purchase.amount.dollars) yet.").foregroundStyle(Brand.slate)
                    }
                    ForEach(matches, id: \.transactionId) { c in
                        Button {
                            Task { await model.setPurchase(purchase, status: .bought, transactionId: c.transactionId); dismiss() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.label).foregroundStyle(Brand.ink)
                                    Text("\(BudgetText.day(c.at)) · \(c.accountName)").font(.caption).foregroundStyle(Brand.slate)
                                }
                                Spacer()
                                Text(c.amount.dollars).monospacedDigit().foregroundStyle(Brand.ink)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Eyebrow("Which charge was it?") }
                footer: { Text("Linking it means the money counts once, through its category.") }
                Section {
                    Button("Bought it, the charge isn't here yet") {
                        Task { await model.setPurchase(purchase, status: .bought); dismiss() }
                    }
                } footer: {
                    Text("Until the charge shows up, the money won't count anywhere. If it's days away, keep the purchase planned instead.")
                }
            }
            .statementBackground()
            .inlineNavTitle("Bought \(purchase.label)?")
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 360)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
