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
            List {
                if !model.spending.isEmpty {
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
            .navigationTitle("Spending")
            .overlay {
                if model.spending.isEmpty {
                    ContentUnavailableView("No spending yet", systemImage: "chart.bar",
                                           description: Text("Sync a connection to see spending by category."))
                }
            }
        }
    }
}
