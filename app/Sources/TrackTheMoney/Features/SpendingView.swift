import SwiftUI
import Charts
import TTMCore

struct SpendingView: View {
    @Bindable var model: AppModel

    private var total: Money {
        model.spending.reduce(Money.zero) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                periodSelector
                list
            }
            .background(Brand.paper.ignoresSafeArea())
            .inlineNavTitle("Spending")
        }
    }

    private var periodSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.spendingPeriods) { period in
                    let selected = model.selectedSpendingPeriod == period.id
                    Button {
                        Task { await model.selectSpendingPeriod(period.id) }
                    } label: {
                        Text(period.label)
                            .font(.system(.subheadline, design: .default).weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Brand.ink)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected ? Brand.evergreen : Brand.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Brand.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Brand.paper)
    }

    private var list: some View {
        List {
            if model.spending.isEmpty {
                Section {
                    Text("No spending in this period.")
                        .foregroundStyle(Brand.slate)
                        .listRowBackground(Brand.surface)
                }
            } else {
                Section {
                    Chart(model.spending.prefix(8)) { line in
                        BarMark(x: .value("Amount", Double(line.amount.cents) / 100),
                                y: .value("Category", line.categoryName))
                        .foregroundStyle(Brand.clay)
                    }
                    .frame(height: 240)
                    .listRowBackground(Brand.surface)
                }
                Section {
                    ForEach(model.spending) { line in
                        HStack {
                            Text(line.categoryName)
                            Spacer()
                            MoneyText(line.amount, size: 16, color: Brand.clay)
                        }
                        .listRowBackground(Brand.surface)
                    }
                    HStack {
                        Text("Total").fontWeight(.semibold)
                        Spacer()
                        MoneyText(total, size: 16, color: Brand.clay)
                    }
                    .listRowBackground(Brand.surface)
                } header: { Eyebrow("By category") }
            }
        }
        .statementBackground()
    }
}
