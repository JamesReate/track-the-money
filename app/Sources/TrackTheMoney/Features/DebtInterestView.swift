import SwiftUI
import TTMCore

struct DebtInterestView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let nw = model.netWorth {
                    Section("Debt") {
                        row("Secured", nw.securedDebt)
                        row("Unsecured", nw.unsecuredDebt)
                        row("Total", nw.securedDebt + nw.unsecuredDebt, emphasize: true)
                    }
                }
                if let interest = model.interest, !interest.byAccount.isEmpty {
                    Section("Interest paid") {
                        ForEach(interest.byAccount, id: \.accountId) { line in
                            row(line.accountName, line.interest)
                        }
                        row("Total", interest.total, emphasize: true)
                    }
                } else {
                    Section("Interest paid") {
                        Text("No interest charges categorized yet.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Debt & Interest")
        }
    }

    private func row(_ label: String, _ amount: Money, emphasize: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasize ? .semibold : .regular)
            Spacer()
            Text(amount.formatted()).monospacedDigit()
                .fontWeight(emphasize ? .semibold : .regular)
                .foregroundStyle(.red)
        }
    }
}
