import SwiftUI
import TTMCore

/// One category's plan for the month (MONTHLY_BUDGET_PLAN.md D3, D4): spent
/// against plan and pace, the plan with a "Use $X" suggestion, the last three
/// months, carry-over and this month's charges.
struct CategoryPlanView: View {
    @Bindable var model: AppModel
    let rowId: String
    @State private var name = ""

    var body: some View {
        ScrollView {
            Group {
                if let b = model.budget, let row = b.rows.first(where: { $0.id == rowId }) {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(row, b)
                        plan(row, b)
                        history(row, b)
                        carry(row, b)
                        if row.isEverythingElse { members(row, b) }
                        charges(row, b)
                    }
                    .onAppear { name = row.name }
                } else {
                    Text("\(name.isEmpty ? "This category" : name) has no plan now; its spending counts in Everything else.")
                        .foregroundStyle(Brand.slate).padding(.top, 40)
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .statementBackground()
        .inlineNavTitle(name)
    }

    private func summary(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        let d = BudgetText.dayAndLeft(b.period)
        let ahead = row.aheadOfPace(b.pace)
        let running = row.left.cents > 0 && ahead.cents > Int64(Double(max(0, row.available.cents)) * 0.08)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if row.isEverythingElse { Circle().stroke(Brand.slate, lineWidth: 1).frame(width: 12, height: 12) }
                else { CategoryDot(hex: row.color, size: 12) }
                Text(row.name).font(.title2.weight(.semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.spent.dollars).font(.serif(42)).monospacedDigit().accessibilityIdentifier("plan-spent")
                Text("of \(row.available.dollars)").font(.title3).foregroundStyle(Brand.slate)
            }
            PlanBar(spent: row.spent + row.reserved, available: row.available, pace: b.pace,
                    ahead: running || row.left.cents < 0, height: 8)
            Text(row.left.cents < 0 ? "Over by \(Money(cents: -row.left.cents).dollars); it comes out of splurge room"
                 : running ? "\(ahead.dollars) ahead of pace · \(row.left.dollars) left for \(d.left + 1) days"
                 : "\(row.left.dollars) left for \(d.left + 1) days")
                .font(.subheadline)
                .foregroundStyle(running || row.left.cents < 0 ? Color(hex: 0x9C4632) : Brand.slate)
            if row.reserved.cents > 0 {
                Text("Includes \(row.reserved.dollars) of planned purchases").font(.caption).foregroundStyle(Brand.slate)
            }
        }
        .padding(20)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
    }

    private func plan(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        BudgetCard(title: "Plan for \(BudgetText.monthName(b.period))") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    stepButton("minus", label: "Lower the plan by $10", id: "plan-minus") {
                        Task { await model.setPlan(row, to: Money(cents: max(0, row.plan.cents - 1_000))) }
                    }
                    .disabled(row.plan.cents == 0)
                    Spacer()
                    Text(row.plan.dollars).font(.serif(34)).monospacedDigit().accessibilityIdentifier("plan-amount")
                    Spacer()
                    stepButton("plus", label: "Raise the plan by $10", id: "plan-plus") {
                        Task { await model.setPlan(row, to: row.plan + Money(cents: 1_000)) }
                    }
                }
                if row.carry.cents != 0 {
                    Text("\(row.carry.cents > 0 ? "+" : "−")\(Money(cents: abs(row.carry.cents)).dollars) carried from last month makes \(row.available.dollars) to spend.")
                        .font(.footnote).foregroundStyle(Brand.slate)
                }
                Divider()
                HStack(spacing: 12) {
                    Text("Your typical month is **\(row.suggested.dollars)** (middle of the last 3).")
                        .font(.footnote).foregroundStyle(Brand.ink.opacity(0.75))
                    Spacer()
                    Button("Use \(row.suggested.dollars)") { Task { await model.setPlan(row, to: row.suggested) } }
                        .buttonStyle(.bordered).tint(Brand.evergreen)
                        .disabled(row.suggested == row.plan)
                        .accessibilityIdentifier("plan-use-typical")
                }
                Text("Raising a plan takes from splurge room (\(max(.zero, b.splurgeRoom).dollars)), never from bills or savings."
                     + (row.isEverythingElse ? "" : " A plan of $0 moves the category into Everything else."))
                    .font(.caption).foregroundStyle(Brand.slate)
            }
            .padding(16)
        }
    }

    private func stepButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3.weight(.medium)).frame(width: 44, height: 44)
                .background(Brand.paper, in: Circle())
                .overlay(Circle().stroke(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.evergreen)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func history(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        let start = Time.date(b.period.span.start)
        let labels = (1...3).reversed().map { i in
            Calendar.current.date(byAdding: .month, value: -i, to: start)?.formatted(.dateTime.month(.abbreviated)) ?? ""
        }
        let months = zip(labels, row.history.reversed()).map { (label: $0, amount: $1, current: false) }
            + [(label: "\(start.formatted(.dateTime.month(.abbreviated))) so far", amount: row.spent, current: true)]
        return BudgetCard(title: "Last three months") {
            VStack(alignment: .leading, spacing: 10) {
                HistoryBars(months: months, plan: row.available)
                HStack(spacing: 6) {
                    Rectangle().stroke(Brand.brass, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 16, height: 1)
                    Text("Plan, \(row.available.dollars)").font(.caption).foregroundStyle(Brand.slate)
                }
            }
            .padding(16)
        }
    }

    private func carry(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: Time.date(b.period.span.start))?
            .formatted(.dateTime.month(.wide)) ?? "next month"
        return BudgetCard {
            Toggle(isOn: Binding(get: { row.carryOn }, set: { on in Task { await model.setCarry(row, on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Carry what's left into \(next)")
                    Text(row.left.cents >= 0 ? "\(row.left.dollars) would join next month's plan; overspending comes off it."
                                             : "\(Money(cents: -row.left.cents).dollars) over would come off next month's plan.")
                        .font(.caption).foregroundStyle(Brand.slate)
                }
            }
            .tint(Brand.evergreen)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityIdentifier("plan-carry")
        }
    }

    private func members(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        let names = Dictionary(model.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let spent = Dictionary(grouping: b.charges.filter { (b.row(for: $0.categoryId)?.id ?? Budget.everythingElseId) == row.id },
                               by: { $0.categoryId ?? "uncategorized" })
            .mapValues { $0.reduce(Money.zero) { $0 + $1.amount } }
        let shown = row.members.filter { (spent[$0]?.cents ?? 0) > 0 }
        return BudgetCard(title: "Categories in here") {
            if shown.isEmpty {
                Text("Categories without a plan of their own, and anything uncategorized, land here.")
                    .font(.footnote).foregroundStyle(Brand.slate).padding(16)
            }
            ForEach(Array(shown.enumerated()), id: \.element) { i, id in
                if i > 0 { Divider().padding(.leading, 16) }
                HStack {
                    Text(names[id] ?? id)
                    Text(spent[id]?.dollars ?? "").font(.footnote).foregroundStyle(Brand.slate)
                    Spacer()
                    Button("Plan separately") {
                        let cents = max(1_000, ((spent[id]?.cents ?? 0) + 999) / 1_000 * 1_000)
                        Task { await model.planSeparately(categoryId: id, plan: Money(cents: cents)) }
                    }
                    .buttonStyle(.borderless).foregroundStyle(Brand.evergreen)
                    .accessibilityIdentifier("plan-separately-\(names[id] ?? id)")
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
    }

    private func charges(_ row: BudgetRow, _ b: BudgetMonth) -> some View {
        let mine = b.charges.filter { (b.row(for: $0.categoryId)?.id ?? Budget.everythingElseId) == row.id }
        return BudgetCard(title: "This month") {
            if mine.isEmpty {
                Text("Nothing spent here yet this month.").font(.footnote).foregroundStyle(Brand.slate).padding(16)
            }
            ForEach(Array(mine.enumerated()), id: \.element.transactionId) { i, c in
                if i > 0 { Divider().padding(.leading, 16) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(c.label).lineLimit(1)
                    Spacer()
                    Text(BudgetText.day(c.at)).font(.caption).foregroundStyle(Brand.slate)
                    Text(c.amount.dollars).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }
}
