import SwiftUI
import TTMCore

struct RealEstateView: View {
    @Bindable var model: AppModel
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.properties) { property in
                    Section {
                        line("Value", property.value, Brand.ink)
                        line("Linked debt", property.linkedDebt, Brand.clay)
                        line("Equity", property.equity, Brand.evergreen, emphasize: true)
                        NavigationLink("Link a mortgage / HELOC account") {
                            LinkDebtView(model: model, propertyId: property.id)
                        }
                        .listRowBackground(Brand.surface)
                    } header: { Eyebrow(property.name) }
                }
            }
            .statementBackground()
            .navigationTitle("Real Estate")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
            .overlay {
                if model.properties.isEmpty {
                    ContentUnavailableView("No properties", systemImage: "house",
                                           description: Text("Add a home or vehicle to track value vs. debt."))
                }
            }
            .sheet(isPresented: $showAdd) { AddPropertyView(model: model) }
        }
    }

    private func line(_ label: String, _ amount: Money, _ color: Color, emphasize: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasize ? .semibold : .regular)
            Spacer()
            MoneyText(amount, size: 16, color: color)
        }
        .listRowBackground(Brand.surface)
    }
}

private struct AddPropertyView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Main House)", text: $name)
                TextField("Estimated value", text: $value)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Button("Add") {
                    let cents = Money(decimalString: value) ?? .zero
                    let n = name
                    Task { await model.addProperty(name: n, value: cents); dismiss() }
                }.disabled(name.isEmpty || Money(decimalString: value) == nil)
            }
            .navigationTitle("Add Property")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct LinkDebtView: View {
    @Bindable var model: AppModel
    let propertyId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(model.accounts.filter { $0.accountClass == .securedDebt }) { account in
            Button {
                Task { await model.linkDebt(propertyId: propertyId, accountId: account.id); dismiss() }
            } label: {
                HStack {
                    Text(account.name)
                    Spacer()
                    Text(account.balance.formatted(currencyCode: account.currency)).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Link debt")
        .overlay {
            if model.accounts.filter({ $0.accountClass == .securedDebt }).isEmpty {
                ContentUnavailableView("No secured-debt accounts", systemImage: "creditcard",
                                       description: Text("Classify a mortgage/HELOC account as Secured debt first."))
            }
        }
    }
}
