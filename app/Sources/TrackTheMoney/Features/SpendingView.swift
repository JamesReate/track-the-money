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
                        }
                        .frame(height: 240)
                    }
                    Section("By category") {
                        ForEach(model.spending) { line in
                            HStack {
                                Text(line.categoryName)
                                Spacer()
                                Text(line.amount.formatted()).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("Total").fontWeight(.semibold)
                            Spacer()
                            Text(total.formatted()).monospacedDigit().fontWeight(.semibold)
                        }
                    }
                }
            }
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
