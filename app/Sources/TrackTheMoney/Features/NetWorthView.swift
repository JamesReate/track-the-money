import SwiftUI
import Charts
import TTMCore

struct NetWorthView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let nw = model.netWorth {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Net Worth").font(.subheadline).foregroundStyle(.secondary)
                            Text(nw.netWorth.formatted())
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(nw.netWorth.cents >= 0 ? Color.primary : Color.red)
                        }.padding(.vertical, 6)
                    }
                    if model.series.count > 1 {
                        Section("Over time") { chart }
                    }
                    Section("Assets") {
                        row("Liquid", nw.liquid)
                        row("Investments", nw.investments)
                        row("Real estate equity", nw.realEstateEquity)
                    }
                    Section("Liabilities") {
                        row("Secured debt", nw.securedDebt)
                        row("Unsecured debt", nw.unsecuredDebt)
                    }
                } else {
                    Section { ProgressView("Loading…") }
                }
            }
            .navigationTitle("Track The Money")
            .refreshable { await model.refresh() }
        }
    }

    private var chart: some View {
        Chart(model.series, id: \.asOf) { point in
            LineMark(x: .value("Date", Date(timeIntervalSince1970: TimeInterval(point.asOf))),
                     y: .value("Net worth", Double(point.netWorth.cents) / 100))
            .interpolationMethod(.monotone)
        }
        .frame(height: 160)
        .padding(.vertical, 4)
    }

    private func row(_ label: String, _ amount: Money) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
