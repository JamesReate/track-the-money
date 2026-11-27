import SwiftUI
import TTMCore

/// This month's budget (docs/plans/MONTHLY_BUDGET_PLAN.md): what's left,
/// splurge room and "Can I afford it?", everyday spending against category
/// plans, big bills (EXPECTED_EXPENSES_PLAN.md) and expected income. One
/// column on iPhone; two on a wide Mac window.
struct ThisMonthView: View {
    @Bindable var model: AppModel
    @State private var affording = false
    @State private var editingGoal = false
    @State private var editingIncome = false
    @State private var buying: PlannedPurchase?

    enum Route: Hashable { case bills, category(String) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let b = model.budget {
                    ViewThatFits(in: .horizontal) {
                        twoColumns(b).frame(minWidth: 860)
                        oneColumn(b)
                    }
                    .padding(16)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                }
            }
            .statementBackground()
            .inlineNavTitle("This Month")
            .toolbar { ToolbarItem(placement: .primaryAction) { options } }
            .refreshable { await model.refresh() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .bills: BigBillsView(model: model)
                case .category(let id): CategoryPlanView(model: model, rowId: id)
                }
            }
            .sheet(isPresented: $affording) { AffordSheet(model: model) }
            .sheet(isPresented: $editingGoal) { SavingsGoalSheet(model: model) }
            .sheet(isPresented: $editingIncome) { IncomeSourcesSheet(model: model) }
            .sheet(item: $buying) { p in MarkBoughtSheet(model: model, purchase: p) }
        }
    }

    // MARK: Layouts

    private func oneColumn(_ b: BudgetMonth) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(b)
            hero(b)
            purchases(b)
            everyday(b)
            bills(b)
            income(b)
            addsUp(b)
        }
    }

    private func twoColumns(_ b: BudgetMonth) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(b)
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    hero(b)
                    everyday(b)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    purchases(b)
                    bills(b)
                    income(b)
                    addsUp(b)
                }
                .frame(width: 360)
            }
        }
    }

    // MARK: Sections

    private func header(_ b: BudgetMonth) -> some View {
        let d = BudgetText.dayAndLeft(b.period)
        return Text("\(BudgetText.monthName(b.period)) · day \(d.day), \(d.left) \(d.left == 1 ? "day" : "days") left")
            .font(.subheadline).foregroundStyle(Brand.slate)
            .padding(.horizontal, 4)
    }

    private func monthParts(_ b: BudgetMonth) -> [MonthBar.Part] {
        [.init(id: "bills", label: "Big bills", amount: b.bills.total, color: Brand.clay),
         .init(id: "savings", label: "Savings", amount: b.savingsGoal, color: Brand.brass),
         .init(id: "spent", label: "Spent", amount: b.everydaySpent, color: Brand.ink),
         .init(id: "planned", label: "Planned, to spend", amount: b.plannedToSpend, color: Color(hex: 0x6E9483)),
         .init(id: "room", label: "Splurge room", amount: max(.zero, b.splurgeRoom), color: Color(hex: 0xCFE0D6))]
    }

    private func hero(_ b: BudgetMonth) -> some View {
        let d = BudgetText.dayAndLeft(b.period)
        let daysToGo = max(1, d.left + 1)
        let left = b.leftThisMonth
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Left this month")
                Text(left.dollars)
                    .font(.serif(46)).monospacedDigit()
                    .foregroundStyle(left.cents < 0 ? Brand.clay : Brand.ink)
                    .accessibilityIdentifier("budget-left")
                Text(left.cents > 0 ? "About \(Money(cents: left.cents / Int64(daysToGo)).dollars) a day for the next \(daysToGo) \(daysToGo == 1 ? "day" : "days")"
                                    : "Spending has run past this month's budget.")
                    .font(.subheadline).foregroundStyle(Brand.slate)
            }
            if b.income.overdue.cents > 0 {
                Label("\(b.income.overdue.dollars) of expected income hasn't landed yet", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Brand.clay)
                    .accessibilityIdentifier("income-overdue")
            }
            VStack(alignment: .leading, spacing: 8) {
                MonthBar(parts: monthParts(b))
                MonthBarLegend(parts: monthParts(b))
                Text("of \(b.income.counted.dollars) expected income" + (b.carriedIn.cents == 0 ? "" : ", \(b.carriedIn.cents > 0 ? "+" : "−")\(Money(cents: abs(b.carriedIn.cents)).dollars) carried over"))
                    .font(.caption).foregroundStyle(Brand.slate)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.splurgeRoom.cents < 0 ? "Over plan by" : "Splurge room").font(.footnote).foregroundStyle(Brand.slate)
                    Text(Money(cents: abs(b.splurgeRoom.cents)).dollars)
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(b.splurgeRoom.cents < 0 ? Brand.clay : Brand.evergreen)
                        .accessibilityIdentifier("budget-splurge")
                }
                Spacer()
                Button("Can I afford…?") { affording = true }
                    .buttonStyle(.borderedProminent).tint(Brand.evergreen)
                    .accessibilityIdentifier("afford-open")
            }
            .padding(12)
            .background(Color(hex: 0xEEF4F0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
    }

    @ViewBuilder private func purchases(_ b: BudgetMonth) -> some View {
        if !b.purchases.isEmpty || !b.earlierOpen.isEmpty {
            BudgetCard(title: "Planned purchases") {
                ForEach(Array(b.purchases.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Divider().padding(.leading, 16) }
                    purchaseRow(p, b)
                }
                ForEach(b.earlierOpen) { p in
                    Divider().padding(.leading, 16)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.label).lineLimit(1)
                            Text("Saved for \(monthLabel(p.month)), not bought").font(.caption).foregroundStyle(Brand.slate)
                        }
                        Spacer()
                        Text(p.amount.dollars).monospacedDigit()
                        Menu {
                            Button("Move to \(BudgetText.monthName(b.period))") { Task { await model.movePurchase(p, to: b.period.key) } }
                            Button("Drop it", role: .destructive) { Task { await model.setPurchase(p, status: .dropped) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityIdentifier("purchase-menu-\(p.label)")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
    }

    private func purchaseRow(_ p: PlannedPurchase, _ b: BudgetMonth) -> some View {
        let status: (String, Color) = switch p.status {
        case .tentative: ("Maybe · doesn't count yet", Brand.slate)
        case .confirmed: ("Planned · counted", Brand.evergreen)
        case .bought: ("Bought", Brand.slate)
        case .dropped: ("Dropped", Brand.slate)
        }
        let row = b.row(for: p.categoryId)
        return HStack(spacing: 10) {
            Image(systemName: p.status == .bought ? "checkmark.circle.fill" : p.status == .confirmed ? "circle.inset.filled" : "circle.dashed")
                .foregroundStyle(p.status == .tentative ? Brand.slate : Brand.evergreen)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.label).foregroundStyle(p.status == .bought ? Brand.slate : Brand.ink).lineLimit(1)
                Text(status.0 + (row.map { " · \($0.name)" } ?? "")).font(.caption).foregroundStyle(status.1)
            }
            Spacer()
            Text(p.amount.dollars).monospacedDigit().foregroundStyle(p.status == .bought ? Brand.slate : Brand.ink)
            if p.isOpen {
                Menu {
                    if p.status == .tentative {
                        Button("Plan it (count it now)") { Task { await model.setPurchase(p, status: .confirmed) } }
                    } else {
                        Button("Make it a maybe") { Task { await model.setPurchase(p, status: .tentative) } }
                    }
                    Button("Mark bought…") { buying = p }
                    Button("Move to \(nextMonthName(b))") { Task { await model.movePurchase(p, to: AppModel.monthKey(after: b.period.key)) } }
                    Button("Drop it", role: .destructive) { Task { await model.setPurchase(p, status: .dropped) } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("purchase-menu-\(p.label)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purchase-\(p.label)")
    }

    private func everyday(_ b: BudgetMonth) -> some View {
        BudgetCard(title: "Everyday spending", trailing: "plan · tick = pace today") {
            if b.needsMoreHistory {
                Text("Plans start from your typical month. Once there are two months of spending they'll fill in; you can set any plan now.")
                    .font(.footnote).foregroundStyle(Brand.slate).padding(16)
            }
            ForEach(Array(b.rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider().padding(.leading, 16) }
                NavigationLink(value: Route.category(row.id)) {
                    CategoryBudgetRow(row: row, pace: b.pace)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("budget-row-\(row.name)")
            }
        }
    }

    private func bills(_ b: BudgetMonth) -> some View {
        let next = b.bills.upcoming.first
        return BudgetCard(title: "Big bills") {
            NavigationLink(value: Route.bills) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(b.bills.paidTotal.dollars) paid · \(b.bills.remainingTotal.dollars) to come")
                        Text(next.map { "Next: \($0.name.capitalized), \($0.status == .late ? "not in yet" : "around \(BudgetText.day($0.expectedOn))")" }
                             ?? (b.bills.total.cents > 0 ? "All paid for \(BudgetText.monthName(b.period))" : "No big recurring bills found"))
                            .font(.caption).foregroundStyle(next?.status == .late ? Brand.clay : Brand.slate)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Brand.slate)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("budget-bills")
        }
    }

    private func income(_ b: BudgetMonth) -> some View {
        let shown = b.income.sources.filter { $0.counted.cents > 0 || $0.mode != .notBudgeted }
        return BudgetCard(title: "Income", trailing: b.income.stillToCome.cents > 0 ? "\(b.income.stillToCome.dollars) to come" : nil) {
            if shown.isEmpty {
                Text("Nothing categorized as Income yet. Categorize paychecks as Income and they'll show here.")
                    .font(.footnote).foregroundStyle(Brand.slate).padding(16)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, source in
                if i > 0 { Divider().padding(.leading, 16) }
                IncomeSourceRows(source: source)
            }
            Divider()
            Button { editingIncome = true } label: {
                Text("Income sources…").font(.subheadline).foregroundStyle(Brand.evergreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("income-sources")
        }
    }

    private func addsUp(_ b: BudgetMonth) -> some View {
        BudgetCard(title: "How it adds up") {
            VStack(spacing: 0) {
                line("Income expected", b.income.counted)
                line("− Big bills", b.bills.total, color: Brand.clay)
                line("− Savings goal", b.savingsGoal, color: Brand.brass)
                if b.carriedIn.cents != 0 {
                    line(b.carriedIn.cents > 0 ? "+ Carried over" : "− Overspent last month", Money(cents: abs(b.carriedIn.cents)))
                }
                line("Everyday budget", b.everydayBudget, bold: true, rule: true)
                line("− Spent so far", b.everydaySpent)
                if b.openConfirmed.cents > 0 { line("− Planned purchases", b.openConfirmed) }
                line("Left this month", b.leftThisMonth, bold: true, rule: true, color: Brand.evergreen)
                Text("Splurge room is the everyday budget minus every category's plan (or what it's spent, if more) and planned purchases.")
                    .font(.caption).foregroundStyle(Brand.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Button("Savings goal: \(b.savingsGoal.dollars) a month…") { editingGoal = true }
                    .font(.subheadline).foregroundStyle(Brand.evergreen).buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .accessibilityIdentifier("savings-goal")
            }
            .padding(16)
        }
    }

    private func line(_ label: String, _ amount: Money, bold: Bool = false, rule: Bool = false, color: Color = Brand.ink) -> some View {
        VStack(spacing: 0) {
            if rule { Rectangle().fill(Brand.hairline).frame(height: 1) }
            HStack {
                Text(label).foregroundStyle(color == Brand.ink ? Brand.ink : color)
                Spacer()
                Text(amount.dollars).monospacedDigit().foregroundStyle(color)
            }
            .font(.subheadline.weight(bold ? .semibold : .regular))
            .padding(.vertical, bold ? 9 : 6)
        }
    }

    // MARK: Toolbar

    private var options: some View {
        Menu {
            Button("Savings goal…") { editingGoal = true }
            Button("Income sources…") { editingIncome = true }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("budget-options")
    }

    private func nextMonthName(_ b: BudgetMonth) -> String {
        Calendar.current.date(byAdding: .month, value: 1, to: Time.date(b.period.span.start))?
            .formatted(.dateTime.month(.wide)) ?? "next month"
    }

    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let d = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return key }
        return d.formatted(.dateTime.month(.wide))
    }
}

/// One everyday-spending line: spent of plan, pace bar, a short note.
struct CategoryBudgetRow: View {
    let row: BudgetRow
    let pace: Double

    var body: some View {
        let ahead = row.aheadOfPace(pace)
        let running = row.left.cents > 0 && ahead.cents > Int64(Double(max(0, row.available.cents)) * 0.08)
        let note: String = row.left.cents < 0 ? "Over by \(Money(cents: -row.left.cents).dollars)"
            : row.left.cents == 0 ? "Done for the month"
            : running ? "\(ahead.dollars) ahead of pace · \(row.left.dollars) left"
            : "\(row.left.dollars) left"
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if row.isEverythingElse {
                    Circle().stroke(Brand.slate, lineWidth: 1).frame(width: 10, height: 10)
                } else {
                    CategoryDot(hex: row.color)
                }
                Text(row.name).lineLimit(1)
                Spacer()
                Text(row.spent.dollars).monospacedDigit()
                Text("/ \(row.available.dollars)").font(.footnote).monospacedDigit().foregroundStyle(Brand.slate)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Brand.slate.opacity(0.7))
            }
            PlanBar(spent: row.spent + row.reserved, available: row.available, pace: pace,
                    ahead: running || row.left.cents < 0)
            Text(note + (row.carry.cents == 0 ? "" : " · \(row.carry.cents > 0 ? "+" : "−")\(Money(cents: abs(row.carry.cents)).dollars) carried"))
                .font(.caption)
                .foregroundStyle(running || row.left.cents < 0 ? Color(hex: 0x9C4632) : Brand.slate)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// A payer's deposits this month: one line per expected paycheck, or one for
/// variable and unbudgeted income.
struct IncomeSourceRows: View {
    let source: IncomeSourceMonth

    var body: some View {
        VStack(spacing: 0) {
            switch source.mode {
            case .regular:
                ForEach(Array(source.slots.enumerated()), id: \.offset) { _, slot in
                    switch slot.status {
                    case .landed(let amount, let on, _):
                        line(icon: "checkmark", tint: Brand.evergreen, detail: BudgetText.day(on), amount: amount, muted: true)
                    case .late:
                        line(icon: "exclamationmark.circle.fill", tint: Brand.clay,
                             detail: "Expected \(BudgetText.day(slot.expectedOn)) · not in yet", amount: slot.expected, late: true)
                    case .upcoming:
                        line(icon: "circle.dashed", tint: Color(hex: 0x6E9483), detail: "~\(BudgetText.day(slot.expectedOn))", amount: slot.expected)
                    }
                }
            case .variable:
                let late = source.overdue.cents > 0
                let detail = source.landed.cents > 0
                    ? "Variable · \(source.landed.dollars) in" + (source.stillToCome.cents > 0 ? ", ~\(source.stillToCome.dollars) more expected" : "")
                    : "Variable · ~\(source.estimate.dollars)" + (source.usuallyOn.map { late ? ", usually by \(BudgetText.day($0)) · not in yet" : ", usually around \(BudgetText.day($0))" } ?? "")
                line(icon: source.stillToCome.cents == 0 ? "checkmark" : late ? "exclamationmark.circle.fill" : "circle.dashed",
                     tint: source.stillToCome.cents == 0 ? Brand.evergreen : late ? Brand.clay : Color(hex: 0x6E9483),
                     detail: detail, amount: source.counted, late: late)
            case .notBudgeted:
                line(icon: "plus.circle", tint: Brand.evergreen, detail: "Extra · not budgeted", amount: source.landed, muted: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("income-\(source.name)")
    }

    private func line(icon: String, tint: Color, detail: String, amount: Money, muted: Bool = false, late: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).foregroundStyle(muted ? Brand.slate : Brand.ink).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(late ? Brand.clay : Brand.slate)
            }
            Spacer()
            Text(amount.dollars).monospacedDigit().foregroundStyle(muted ? Brand.slate : Brand.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
