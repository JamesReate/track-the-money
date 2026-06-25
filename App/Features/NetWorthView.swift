import SwiftUI
import TTMCore

/// Starter Net Worth screen. Renders a static placeholder summary today; wire it
/// to `CoreFacade.netWorthSummary()` once the facade implementation lands.
struct NetWorthView: View {
    private let summary = NetWorth.summary(
        accounts: [
            AccountBalance(accountClass: .liquid, balance: Money(cents: 1_250_000)),
            AccountBalance(accountClass: .investment, balance: Money(cents: 8_400_000)),
            AccountBalance(accountClass: .securedDebt, balance: Money(cents: 31_000_000)),
            AccountBalance(accountClass: .unsecuredDebt, balance: Money(cents: 420_000)),
        ],
        propertyValues: [Money(cents: 52_000_000)],
        asOf: 0
    )

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Net Worth").font(.headline).foregroundStyle(.secondary)
                        Text(summary.netWorth.formatted())
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                    }
                    .padding(.vertical, 8)
                }
                Section("Assets") {
                    row("Liquid", summary.liquid)
                    row("Investments", summary.investments)
                    row("Real estate", summary.realEstateEquity)
                }
                Section("Liabilities") {
                    row("Secured debt", summary.securedDebt)
                    row("Unsecured debt", summary.unsecuredDebt)
                }
            }
            .navigationTitle("Track The Money")
        }
    }

    private func row(_ label: String, _ amount: Money) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NetWorthView()
}
