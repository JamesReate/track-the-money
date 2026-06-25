import SwiftUI
import TTMCore

struct TransactionsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selected: TransactionRecord?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.recentTransactions, id: \.id) { txn in
                    Button { selected = txn } label: { row(txn) }
                        .buttonStyle(.plain)
                        .listRowBackground(Brand.surface)
                }
            }
            .statementBackground()
            .inlineNavTitle("Transactions")
            .searchable(text: $query, prompt: "Search description or payee")
            .onChange(of: query) { _, newValue in Task { await model.search(newValue) } }
            .sheet(item: $selected) { txn in
                CategorizeSheet(model: model, txn: txn)
            }
        }
    }

    private func row(_ txn: TransactionRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.description).lineLimit(1)
                HStack(spacing: 6) {
                    if let posted = txn.postedAt {
                        Text(Date(timeIntervalSince1970: TimeInterval(posted)), format: .dateTime.month().day())
                    }
                    Text(model.categoryName(txn.categoryId))
                    if txn.pending { Text("PENDING").foregroundStyle(.orange) }
                    if txn.isTransfer { Text("TRANSFER") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(Money(cents: txn.amountCents), size: 16,
                      color: txn.amountCents < 0 ? Brand.ink : Brand.evergreen)
        }
        .contentShape(Rectangle())
    }
}

/// Sheet to set a category on one transaction, or turn it into a reusable rule.
private struct CategorizeSheet: View {
    @Bindable var model: AppModel
    let txn: TransactionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var categoryId: String = ""

    private var ruleText: String { (txn.payee?.isEmpty == false ? txn.payee! : txn.description) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    Text(txn.description)
                    Text(Money(cents: txn.amountCents).formatted()).foregroundStyle(.secondary)
                }
                Section("Category") {
                    Picker("Category", selection: $categoryId) {
                        Text("— none —").tag("")
                        ForEach(model.categories) { c in Text(c.name).tag(c.id) }
                    }
                }
                Section {
                    Button("Set category for this transaction") {
                        Task { await model.setCategory(transactionId: txn.id, categoryId: categoryId.isEmpty ? nil : categoryId); dismiss() }
                    }.disabled(categoryId.isEmpty)
                    Button("Create rule: contains “\(ruleText)” → category") {
                        Task { await model.createRule(fromText: ruleText, categoryId: categoryId); dismiss() }
                    }.disabled(categoryId.isEmpty || ruleText.isEmpty)
                }
            }
            .navigationTitle("Categorize")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { categoryId = txn.categoryId ?? "" }
        }
    }
}
