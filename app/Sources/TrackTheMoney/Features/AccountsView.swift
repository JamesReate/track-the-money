import SwiftUI
import TTMCore

struct AccountsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.accounts) { account in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Brand.ink)
                            Menu {
                                Picker("Class", selection: classBinding(account)) {
                                    ForEach(AccountClass.allCases, id: \.self) { cls in
                                        Text(label(cls)).tag(cls)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(dot(account.accountClass)).frame(width: 6, height: 6)
                                    Text(label(account.accountClass).uppercased())
                                        .font(.system(.caption2).weight(.semibold)).tracking(0.8)
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                                }
                                .foregroundStyle(Brand.slate)
                            }
                        }
                        Spacer()
                        MoneyText(account.balance, size: 17,
                                  color: account.accountClass.contribution == .liability ? Brand.clay : Brand.evergreen,
                                  currency: account.currency)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Brand.surface)
                }
            }
            .statementBackground()
            .inlineNavTitle("Accounts")
            .overlay { if model.accounts.isEmpty { ContentUnavailableView("No accounts", systemImage: "building.columns", description: Text("Add a SimpleFIN connection in Settings.")) } }
        }
    }

    private func classBinding(_ account: AccountSummary) -> Binding<AccountClass> {
        Binding(
            get: { account.accountClass },
            set: { newValue in Task { await model.setClass(accountId: account.id, to: newValue) } }
        )
    }

    private func dot(_ cls: AccountClass) -> Color {
        switch cls.contribution {
        case .asset: return Brand.evergreen
        case .liability: return Brand.clay
        case .ignored: return Brand.slate
        }
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
