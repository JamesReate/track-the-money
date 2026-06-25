import SwiftUI
import TTMCore

struct DebtInterestView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let nw = model.netWorth {
                    Section {
                        row("Secured", nw.securedDebt)
                        row("Unsecured", nw.unsecuredDebt)
                        row("Total", nw.securedDebt + nw.unsecuredDebt, emphasize: true)
                    } header: { Eyebrow("Debt") }
                }
                if let interest = model.interest, !interest.byAccount.isEmpty {
                    Section {
                        ForEach(interest.byAccount, id: \.accountId) { line in
                            row(line.accountName, line.interest)
                        }
                        row("Total", interest.total, emphasize: true)
                    } header: { Eyebrow("Interest paid") }
                } else {
                    Section {
                        Text("No interest charges categorized yet.").foregroundStyle(Brand.slate)
                            .listRowBackground(Brand.surface)
                    } header: { Eyebrow("Interest paid") }
                }
            }
            .statementBackground()
            .navigationTitle("Debt & Interest")
        }
    }

    private func row(_ label: String, _ amount: Money, emphasize: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasize ? .semibold : .regular)
            Spacer()
            MoneyText(amount, size: 16, color: Brand.clay)
                .fontWeight(emphasize ? .semibold : .regular)
        }
        .listRowBackground(Brand.surface)
    }
}
