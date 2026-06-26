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
                    TxnRow(model: model, txn: txn) { selected = txn }
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
}

/// One transaction row. Reflects the current category and glows briefly when it
/// was just (re)categorized.
private struct TxnRow: View {
    @Bindable var model: AppModel
    let txn: TransactionRecord
    let onTap: () -> Void
    @State private var glow = false

    private var isCategorized: Bool { txn.categoryId != nil }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(txn.description).foregroundStyle(Brand.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        if let posted = txn.postedAt {
                            Text(Date(timeIntervalSince1970: TimeInterval(posted)), format: .dateTime.month().day())
                        }
                        Text(model.categoryName(txn.categoryId))
                            .foregroundStyle(isCategorized ? Brand.evergreen : Brand.slate)
                        if txn.pending { Text("PENDING").foregroundStyle(.orange) }
                        if txn.isTransfer { Text("TRANSFER") }
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.slate)
                }
                Spacer()
                MoneyText(Money(cents: txn.amountCents), size: 16,
                          color: txn.amountCents < 0 ? Brand.ink : Brand.evergreen)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(glow ? Brand.evergreen.opacity(0.14) : Brand.surface)
        .onChange(of: model.lastCategorized) { _, id in
            guard id == txn.id else { return }
            withAnimation(.easeIn(duration: 0.12)) { glow = true }
            Task {
                try? await Task.sleep(for: .seconds(0.85))
                withAnimation(.easeOut(duration: 0.9)) { glow = false }
                if model.lastCategorized == txn.id { model.lastCategorized = nil }
            }
        }
    }
}

/// Tap a category to apply it immediately. The "Also create a rule" toggle lets
/// one tap both categorize this transaction and auto-categorize future ones.
private struct CategorizeSheet: View {
    @Bindable var model: AppModel
    let txn: TransactionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var makeRule = false

    private var ruleText: String { (txn.payee?.isEmpty == false ? txn.payee! : txn.description) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(txn.description)
                    MoneyText(Money(cents: txn.amountCents), size: 16, color: Brand.ink)
                } header: { Eyebrow("Transaction") }
                .listRowBackground(Brand.surface)

                Section {
                    Toggle(isOn: $makeRule) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also create a rule")
                            Text("Auto-categorize future “\(ruleText)”")
                                .font(.caption).foregroundStyle(Brand.slate)
                        }
                    }.tint(Brand.evergreen)
                }
                .listRowBackground(Brand.surface)

                Section {
                    ForEach(model.categories) { category in
                        Button { apply(category.id) } label: {
                            HStack {
                                Text(category.name).foregroundStyle(Brand.ink)
                                Spacer()
                                if txn.categoryId == category.id {
                                    Image(systemName: "checkmark").foregroundStyle(Brand.evergreen)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    if txn.categoryId != nil {
                        Button("Clear category", role: .destructive) { apply(nil) }
                    }
                } header: { Eyebrow("Choose a category") }
                .listRowBackground(Brand.surface)
            }
            .statementBackground()
            .inlineNavTitle("Categorize")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func apply(_ categoryId: String?) {
        Task {
            if makeRule, let categoryId {
                await model.createRule(fromText: ruleText, categoryId: categoryId, highlight: txn.id)
            } else {
                await model.setCategory(transactionId: txn.id, categoryId: categoryId)
            }
            dismiss()
        }
    }
}
