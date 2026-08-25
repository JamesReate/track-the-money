import SwiftUI
import TTMCore

struct TransactionsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selected: TransactionRecord?
    @State private var reviewing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List {
                    ForEach(model.recentTransactions, id: \.id) { txn in
                        TxnRow(model: model, txn: txn) { selected = txn }
                    }
                    if model.recentTransactions.isEmpty {
                        Text(model.txnFilter == .uncategorized ? "Nothing to review — all caught up." : "No transactions.")
                            .foregroundStyle(Brand.slate)
                            .listRowBackground(Brand.surface)
                    }
                }
                .statementBackground()
            }
            .background(Brand.paper.ignoresSafeArea())
            .inlineNavTitle("Transactions")
            .searchable(text: $query, prompt: "Search description or payee")
            .onChange(of: query) { _, newValue in Task { await model.search(newValue) } }
            .sheet(item: $selected) { txn in
                CategorizeSheet(model: model, txn: txn)
            }
            .sheet(isPresented: $reviewing) {
                ReviewView(model: model)
            }
            // Test hook: auto-open the categorize sheet on the first transaction so
            // a real-keyboard driver can verify search without click-targeting a row.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-debugCategorize") else { return }
                for _ in 0..<50 {
                    if let first = model.recentTransactions.first { selected = first; return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Categorized / uncategorized chips. The Uncategorized chip carries the
    /// outstanding count and, tapped, also opens the guided Review flow.
    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(title: "All", selected: model.txnFilter == .all) {
                Task { await model.setTxnFilter(.all) }
            }
            FilterChip(title: "Uncategorized", count: model.uncategorizedCount,
                       selected: model.txnFilter == .uncategorized) {
                Task { await model.setTxnFilter(.uncategorized) }
            }
            FilterChip(title: "Categorized", selected: model.txnFilter == .categorized) {
                Task { await model.setTxnFilter(.categorized) }
            }
            Spacer()
            if model.uncategorizedCount > 0 {
                Button { reviewing = true } label: {
                    Label("Review", systemImage: "checklist").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.evergreen)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Brand.paper)
    }
}

/// A small pill toggle used by the Transactions filter bar.
private struct FilterChip: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Brand.clay.opacity(0.15))
                        .foregroundStyle(selected ? Color.white : Brand.clay)
                        .clipShape(Capsule())
                }
            }
            .font(.system(.subheadline, design: .default).weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Brand.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Brand.evergreen : Brand.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
                        if isCategorized { CategoryDot(hex: model.categoryColorHex(txn.categoryId), size: 7) }
                        Text(model.categoryName(txn.categoryId))
                            .foregroundStyle(isCategorized ? Brand.ink : Brand.clay)
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

/// Search, pick, or create-on-the-fly. The "Also create a rule" toggle lets one
/// tap both categorize this transaction and auto-categorize future ones.
private struct CategorizeSheet: View {
    @Bindable var model: AppModel
    let txn: TransactionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var makeRule = false
    @State private var search = ""
    @State private var suggestion: CategorySuggestion?
    @State private var suggesting = false

    private var ruleText: String { (txn.payee?.isEmpty == false ? txn.payee! : txn.description) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if suggesting || suggestion != nil {
                    AISuggestionView(model: model, loading: suggesting, suggestion: suggestion,
                                     onApprove: { apply($0) })
                        .padding(.horizontal, 16).padding(.top, 12)
                }
                CategoryPicker(model: model, search: $search, currentCategoryId: txn.categoryId,
                               suggestedCategoryId: suggestion?.categoryId,
                               onPick: { apply($0) },
                               onCreate: { name, parent in createThenApply(name: name, parent: parent) })
            }
            // Only assist uncategorized transactions; re-categorizing skips the AI.
            .task {
                guard txn.categoryId == nil else { return }
                suggesting = true
                suggestion = await model.suggestCategory(for: txn.id)
                suggesting = false
            }
            .background(Brand.paper.ignoresSafeArea())
            .inlineNavTitle("Categorize")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if txn.categoryId != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) {
                            Task { await model.setCategory(transactionId: txn.id, categoryId: nil); dismiss() }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(txn.description).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink).lineLimit(1)
                    Text("Now: \(model.categoryName(txn.categoryId))")
                        .font(.caption2).foregroundStyle(Brand.slate)
                }
                Spacer()
                MoneyText(Money(cents: txn.amountCents), size: 15, color: Brand.ink)
            }
            Toggle(isOn: $makeRule) {
                Text("Also create a rule for “\(ruleText)”").font(.caption)
            }.tint(Brand.evergreen)
        }
        .padding(16)
        .background(Brand.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }

    private func apply(_ categoryId: String) {
        Task {
            if makeRule {
                await model.createRule(fromText: ruleText, categoryId: categoryId, highlight: txn.id)
            } else {
                await model.setCategory(transactionId: txn.id, categoryId: categoryId)
            }
            dismiss()
        }
    }

    private func createThenApply(name: String, parent: String?) {
        Task {
            guard let newId = await model.createCategory(name: name, parentId: parent) else { return }
            apply(newId)
        }
    }
}
