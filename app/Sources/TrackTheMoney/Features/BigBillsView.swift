import SwiftUI
import TTMCore

/// This month's big recurring bills: what's still to come and what's already
/// in (docs/plans/EXPECTED_EXPENSES_PLAN.md, ADR-0027). Reached from This
/// Month's Big Bills row; the budget counts their total.
struct BigBillsView: View {
    @Bindable var model: AppModel

    var body: some View {
            List {
                if let month = model.expectedMonth {
                    summary(month)
                    if month.needsMoreHistory {
                        note("Expected expenses need at least two months of history. They'll appear here once there's enough.")
                    } else if month.upcoming.isEmpty && month.paid.isEmpty {
                        note("No recurring charges of \(minimumLabel(month.settings.minimum)) or more in the last \(month.settings.lookbackMonths) months.")
                    }
                    if !month.upcoming.isEmpty { comingUp(month.upcoming) }
                    if !month.paid.isEmpty { paid(month.paid) }
                    if !month.dismissed.isEmpty { removed(month.dismissed) }
                }
            }
            .statementBackground()
            .inlineNavTitle("Big Bills")
            .toolbar { ToolbarItem(placement: .primaryAction) { options } }
            .refreshable { await model.refresh() }
    }

    // MARK: Sections

    private func summary(_ month: ExpectedMonth) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                MoneyText(month.total, size: 40, serif: true)
                    .accessibilityIdentifier("expected-total")
                HStack(alignment: .top, spacing: 28) {
                    figure("Paid", month.paidTotal, color: Brand.evergreen, id: "expected-paid")
                    figure("Still to come", month.remainingTotal, color: Brand.clay, id: "expected-remaining")
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Brand.surface)
        } header: {
            Eyebrow("Big bills · \(Date().formatted(.dateTime.month(.wide)))")
        } footer: {
            Text("Charges of \(minimumLabel(month.settings.minimum)) or more seen in at least 2 of the last \(month.settings.lookbackMonths) months. Swipe or right-click one to remove it.")
                .font(.caption).foregroundStyle(Brand.slate)
        }
    }

    private func comingUp(_ items: [ExpectedExpense]) -> some View {
        Section {
            ForEach(items.map { (key: "up-\($0.key)", item: $0) }, id: \.key) { _, item in
                row(item) {
                    let late = item.status == .late
                    Text(late ? "Expected \(day(item.expectedOn)) · not in yet"
                              : "Around \(day(item.expectedOn)) · \(item.monthsSeen) of \(item.lookbackMonths) months")
                        .font(.caption).foregroundStyle(late ? Brand.clay : Brand.slate)
                } amount: {
                    MoneyText(item.expected, size: 16)
                }
                .accessibilityIdentifier("expected-\(item.name)")
            }
        } header: { Eyebrow("Coming up") }
    }

    private func paid(_ items: [ExpectedExpense]) -> some View {
        Section {
            ForEach(items.map { (key: "paid-\($0.key)", item: $0) }, id: \.key) { _, item in
                row(item, done: true) {
                    if case .paid(let amount, let on, _) = item.status {
                        Text("Paid \(day(on))" + (amount == item.expected ? "" : " · expected \(item.expected.formatted())"))
                            .font(.caption).foregroundStyle(Brand.slate)
                    }
                } amount: {
                    MoneyText(item.monthAmount, size: 16, color: Brand.slate)
                }
                .accessibilityIdentifier("paid-\(item.name)")
            }
        } header: { Eyebrow("Paid this month") }
    }

    private func removed(_ items: [DismissedExpense]) -> some View {
        Section {
            ForEach(items.map { (key: "removed-\($0.key)", item: $0) }, id: \.key) { _, item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).foregroundStyle(Brand.slate).lineLimit(1)
                        Text("Removed \(day(item.dismissedAt))").font(.caption).foregroundStyle(Brand.slate)
                    }
                    Spacer()
                    Button("Restore") { Task { await model.restoreExpected(item) } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Brand.evergreen)
                        .accessibilityIdentifier("restore-\(item.name)")
                }
                .listRowBackground(Brand.surface)
            }
        } header: { Eyebrow("Removed") } footer: {
            Text("Removed merchants aren't expected again until you restore them.")
                .font(.caption).foregroundStyle(Brand.slate)
        }
    }

    // MARK: Pieces

    private func row<Detail: View, Amount: View>(_ item: ExpectedExpense, done: Bool = false,
                                                 @ViewBuilder detail: () -> Detail,
                                                 @ViewBuilder amount: () -> Amount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.evergreen)
            } else {
                CategoryDot(hex: model.categoryColorHex(item.categoryId))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).foregroundStyle(done ? Brand.slate : Brand.ink).lineLimit(1)
                detail()
            }
            Spacer()
            amount()
        }
        .contentShape(Rectangle())
        .listRowBackground(Brand.surface)
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive) { Task { await model.dismissExpected(item) } }
        }
        .contextMenu {
            Button("Remove from expected", systemImage: "minus.circle", role: .destructive) {
                Task { await model.dismissExpected(item) }
            }
        }
    }

    private func figure(_ title: String, _ money: Money, color: Color, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Brand.slate)
            MoneyText(money, size: 18, color: color).accessibilityIdentifier(id)
        }
    }

    private func note(_ text: String) -> some View {
        Section { Text(text).foregroundStyle(Brand.slate).listRowBackground(Brand.surface) }
    }

    /// Detection settings: the minimum charge and how far back to look.
    private var options: some View {
        Menu {
            if let settings = model.expectedMonth?.settings {
                Picker("Minimum", selection: Binding(
                    get: { settings.minimum.cents },
                    set: { cents in Task { await model.setExpectedSettings(.init(minimum: Money(cents: cents), lookbackMonths: settings.lookbackMonths)) } }
                )) {
                    ForEach(ExpectedExpenseSettings.minimumChoices, id: \.cents) { choice in
                        Text("\(minimumLabel(choice)) or more").tag(choice.cents)
                    }
                }
                Picker("Look back", selection: Binding(
                    get: { settings.lookbackMonths },
                    set: { months in Task { await model.setExpectedSettings(.init(minimum: settings.minimum, lookbackMonths: months)) } }
                )) {
                    ForEach(ExpectedExpenseSettings.lookbackChoices, id: \.self) { months in
                        Text("Last \(months) months").tag(months)
                    }
                }
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("expected-options")
    }

    private func minimumLabel(_ money: Money) -> String {
        money.cents % 100 == 0 ? "$\(money.cents / 100)" : money.formatted()
    }

    private func day(_ t: UnixTime) -> String {
        Time.date(t).formatted(.dateTime.month(.abbreviated).day())
    }
}
