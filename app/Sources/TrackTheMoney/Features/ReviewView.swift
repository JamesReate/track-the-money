import SwiftUI
import TTMCore

/// Guided one-at-a-time pass over uncategorized transactions (CATEGORIZATION_PLAN.md
/// §4, phase 5). Reuses the same searchable picker as the categorize sheet; picking
/// a category advances to the next item. Progress + skip keep it a fast sweep.
struct ReviewView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var queue: [TransactionRecord] = []
    @State private var index = 0
    @State private var categorized = 0
    @State private var search = ""
    @State private var makeRule = false
    @State private var loaded = false
    @State private var suggestion: CategorySuggestion?
    @State private var suggesting = false

    private var current: TransactionRecord? { index < queue.count ? queue[index] : nil }
    private var ruleText: String { current.map { $0.payee?.isEmpty == false ? $0.payee! : $0.description } ?? "" }

    var body: some View {
        NavigationStack {
            Group {
                if let txn = current {
                    reviewList(txn)
                } else {
                    completion
                }
            }
            .background(Brand.paper.ignoresSafeArea())
            .inlineNavTitle("Review")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { finish() } } }
        }
        .task {
            guard !loaded else { return }
            queue = await model.fetchUncategorized()
            loaded = true
        }
    }

    private func reviewList(_ txn: TransactionRecord) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                    .tint(Brand.evergreen)
                Text("\(index + 1) of \(queue.count) · \(categorized) categorized")
                    .font(.caption).foregroundStyle(Brand.slate)
                HStack {
                    Text(txn.description).font(.headline).foregroundStyle(Brand.ink).lineLimit(1)
                    Spacer()
                    MoneyText(Money(cents: txn.amountCents), size: 17, serif: true,
                              color: txn.amountCents < 0 ? Brand.ink : Brand.evergreen)
                }
                HStack {
                    Toggle(isOn: $makeRule) {
                        Text("Also create a rule").font(.caption)
                    }.tint(Brand.evergreen).fixedSize()
                    Spacer()
                    Button { skip() } label: {
                        Label("Skip", systemImage: "arrow.uturn.forward").font(.subheadline).foregroundStyle(Brand.slate)
                    }.buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Brand.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }

            if suggesting || suggestion != nil {
                AISuggestionView(model: model, loading: suggesting, suggestion: suggestion,
                                 onApprove: { apply($0, to: txn) })
                    .padding(.horizontal, 16).padding(.top, 12)
            }

            CategoryPicker(model: model, search: $search, currentCategoryId: nil,
                           suggestedCategoryId: suggestion?.categoryId,
                           onPick: { apply($0, to: txn) },
                           onCreate: { name, parent in createThenApply(name: name, parent: parent, to: txn) })
                .id(txn.id)   // reset picker state per transaction
        }
        // Fetch a fresh on-device suggestion whenever the reviewed transaction changes.
        .task(id: txn.id) {
            suggesting = true
            suggestion = await model.suggestCategory(for: txn.id)
            suggesting = false
        }
    }

    private var completion: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Brand.evergreen)
            Text(queue.isEmpty ? "Nothing to review" : "Review complete").font(.serif(22))
            Text("\(categorized) categorized in this pass.").font(.subheadline).foregroundStyle(Brand.slate)
            Button { finish() } label: {
                Text("Done").fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Brand.evergreen).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func apply(_ categoryId: String, to txn: TransactionRecord) {
        Task {
            if makeRule {
                await model.createRule(fromText: ruleText, categoryId: categoryId, highlight: txn.id)
            } else {
                await model.setCategory(transactionId: txn.id, categoryId: categoryId)
            }
            categorized += 1
            advance()
        }
    }

    private func createThenApply(name: String, parent: String?, to txn: TransactionRecord) {
        Task {
            guard let newId = await model.createCategory(name: name, parentId: parent) else { return }
            apply(newId, to: txn)
        }
    }

    private func advance() { search = ""; makeRule = false; suggestion = nil; index += 1 }
    private func skip() { advance() }

    private func finish() {
        Task { try? await model.reloadTransactions(); dismiss() }
    }
}
