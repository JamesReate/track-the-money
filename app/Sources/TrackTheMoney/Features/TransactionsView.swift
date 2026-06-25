import SwiftUI
import TTMCore

struct TransactionsView: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.recentTransactions, id: \.id) { txn in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(txn.description).lineLimit(1)
                            HStack(spacing: 6) {
                                if let posted = txn.postedAt {
                                    Text(Date(timeIntervalSince1970: TimeInterval(posted)), format: .dateTime.month().day())
                                }
                                if txn.pending { Text("PENDING").font(.caption2).foregroundStyle(.orange) }
                                if txn.isTransfer { Text("TRANSFER").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money(cents: txn.amountCents).formatted())
                            .monospacedDigit()
                            .foregroundStyle(txn.amountCents < 0 ? Color.primary : Color.green)
                    }
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $query, prompt: "Search description or payee")
            .onChange(of: query) { _, newValue in Task { await model.search(newValue) } }
        }
    }
}
