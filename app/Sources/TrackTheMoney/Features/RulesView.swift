import SwiftUI
import TTMCore

struct RulesView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).lineLimit(1)
                            Text("→ \(model.categoryName(rule.categoryId))  ·  priority \(rule.priority)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { _ in Task { await model.toggleRule(rule) } }
                        )).labelsHidden()
                    }
                    .listRowBackground(Brand.surface)
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await model.deleteRule(rule.id) } }
                    }
                }
            }
            .statementBackground()
            .navigationTitle("Rules")
            .overlay {
                if model.rules.isEmpty {
                    ContentUnavailableView("No rules", systemImage: "slider.horizontal.3",
                                           description: Text("Create rules from the Transactions tab."))
                }
            }
        }
    }
}
