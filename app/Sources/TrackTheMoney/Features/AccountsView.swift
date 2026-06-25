import SwiftUI
import TTMCore

struct AccountsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Picker("Class", selection: classBinding(account)) {
                                ForEach(AccountClass.allCases, id: \.self) { cls in
                                    Text(label(cls)).tag(cls)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.caption)
                        }
                        Spacer()
                        MoneyText(account.balance, size: 16,
                                  color: account.accountClass.contribution == .liability ? Brand.clay : Brand.evergreen,
                                  currency: account.currency)
                    }
                    .listRowBackground(Brand.surface)
                }
            }
            .statementBackground()
            .navigationTitle("Accounts")
            .overlay { if model.accounts.isEmpty { ContentUnavailableView("No accounts", systemImage: "building.columns", description: Text("Add a SimpleFIN connection in Settings.")) } }
        }
    }

    private func classBinding(_ account: AccountSummary) -> Binding<AccountClass> {
        Binding(
            get: { account.accountClass },
            set: { newValue in Task { await model.setClass(accountId: account.id, to: newValue) } }
        )
    }

    private func label(_ cls: AccountClass) -> String {
        switch cls {
        case .liquid: return "Liquid"
        case .investment: return "Investment"
        case .securedDebt: return "Secured debt"
        case .unsecuredDebt: return "Unsecured debt"
        case .realEstate: return "Real estate"
        case .income: return "Income"
        case .excluded: return "Excluded"
        case .unclassified: return "Unclassified"
        }
    }
}
