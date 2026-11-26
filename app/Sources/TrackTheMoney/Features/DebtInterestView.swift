import SwiftUI
import Charts
import TTMCore

struct DebtInterestView: View {
    @Bindable var model: AppModel
    @State private var range: DebtRange = .all
    @State private var settingRate: AccountSummary?

    /// Debt accounts, highest rate first (unset rates last): the order to pay
    /// them down in if you're minimizing interest.
    private var debts: [AccountSummary] {
        model.accounts.filter { $0.accountClass.isDebt }.sorted {
            switch ($0.aprBps, $1.aprBps) {
            case let (a?, b?): return a != b ? a > b : $0.name < $1.name
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.name < $1.name
            }
        }
    }

    /// Balance-weighted average APR across debts that have one.
    private var weightedAPR: Int? {
        // Integer math: cents × bps stays far inside Int64 for any real balance.
        let rated = debts.compactMap { d in d.aprBps.map { (abs(d.balance.cents), Int64($0)) } }
        let total = rated.reduce(Int64(0)) { $0 + $1.0 }
        guard total > 0 else { return nil }
        let weighted = rated.reduce(Int64(0)) { $0 + $1.0 * $1.1 }
        return Int((weighted + total / 2) / total)
    }

    /// Trailing window for the debt chart.
    private enum DebtRange: String, CaseIterable, Identifiable {
        case sixMonths = "6M", oneYear = "1Y", all = "All"
        var id: String { rawValue }
        var months: Int? { switch self { case .sixMonths: 6; case .oneYear: 12; case .all: nil } }
    }

    /// Points within the selected window. Each point is an absolute total, so a
    /// plain date filter is correct (no carry-forward math needed here).
    private var filteredSeries: [DebtPoint] {
        guard let months = range.months,
              let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) else {
            return model.debtSeries
        }
        let c = Int64(cutoff.timeIntervalSince1970)
        return model.debtSeries.filter { $0.asOf >= c }
    }

    var body: some View {
        NavigationStack {
            List {
                debtOverTime
                if let nw = model.netWorth {
                    Section {
                        row("Secured", nw.securedDebt, dot: Brand.claySoft)
                        row("Unsecured", nw.unsecuredDebt, dot: Brand.clay)
                        row("Total", nw.securedDebt + nw.unsecuredDebt, emphasize: true)
                    } header: { Eyebrow("Debt today") }
                }
                if !debts.isEmpty { interestRates }
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
            .inlineNavTitle("Debt & Interest")
            .sheet(item: $settingRate) { account in InterestRateSheet(model: model, account: account) }
        }
    }

    private var interestRates: some View {
        Section {
            ForEach(debts) { debt in
                Button { settingRate = debt } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(debt.name).foregroundStyle(Brand.ink).lineLimit(1)
                            MoneyText(Money(cents: abs(debt.balance.cents)), size: 13, color: Brand.slate,
                                      currency: debt.currency)
                        }
                        Spacer()
                        if let apr = debt.aprBps {
                            Text(APR.format(apr)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.clay)
                        } else {
                            Text("Set rate").font(.callout).foregroundStyle(Brand.brass)
                        }
                    }
                    .contentShape(Rectangle())   // plain buttons only hit their content otherwise
                }
                .buttonStyle(.plain)
                .listRowBackground(Brand.surface)
                .accessibilityIdentifier("rate-\(debt.name)")
            }
            if let avg = weightedAPR {
                HStack {
                    Text("Weighted average").fontWeight(.semibold)
                    Spacer()
                    Text(APR.format(avg)).fontWeight(.semibold).foregroundStyle(Brand.clay)
                }
                .listRowBackground(Brand.surface)
            }
        } header: { Eyebrow("Interest rates") }
        footer: { Text("Highest rate first. Tap a debt to set or change its APR.") }
    }

    // Stacked-area debt trend: secured (lighter clay) under unsecured (darker clay),
    // so both the composition and the total are readable at a glance.
    @ViewBuilder private var debtOverTime: some View {
        Section {
            rangeChips.listRowBackground(Brand.surface)
            if filteredSeries.count < 2 {
                Text(model.debtSeries.count < 2
                     ? "Your debt trend appears here once there are a couple of balance snapshots."
                     : "Not enough history in this range.")
                    .font(.caption).foregroundStyle(Brand.slate)
                    .listRowBackground(Brand.surface)
            } else {
                Chart(bands) { b in
                    AreaMark(x: .value("Date", b.date),
                             y: .value("Amount", b.amount),
                             stacking: .standard)
                    .foregroundStyle(by: .value("Type", b.type))
                }
                .chartForegroundStyleScale(domain: ["Secured", "Unsecured"],
                                           range: [Brand.claySoft, Brand.clay])
                .chartYAxis { AxisMarks { value in
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(compactDollars(v)) } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                } }
                .chartLegend(position: .top, alignment: .leading, spacing: 8)
                .frame(height: 210)
                .listRowBackground(Brand.surface)
            }
        } header: { Eyebrow("Debt over time") }
    }

    private struct DebtBand: Identifiable {
        let id = UUID()
        let date: Date
        let type: String
        let amount: Double
    }

    private var rangeChips: some View {
        HStack(spacing: 8) {
            ForEach(DebtRange.allCases) { r in
                let selected = range == r
                Button { range = r } label: {
                    Text(r.rawValue)
                        .font(.system(.subheadline, design: .default).weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Brand.ink)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(selected ? Brand.clay : Brand.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Brand.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    /// Long-format rows (one per type per date) for the stacked area chart.
    private var bands: [DebtBand] {
        filteredSeries.flatMap { p -> [DebtBand] in
            let d = Date(timeIntervalSince1970: TimeInterval(p.asOf))
            return [
                DebtBand(date: d, type: "Secured", amount: Double(p.secured.cents) / 100),
                DebtBand(date: d, type: "Unsecured", amount: Double(p.unsecured.cents) / 100),
            ]
        }
    }

    /// Compact axis money: $1.2M / $42k / $900.
    private func compactDollars(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000 { return "$\(trim(v / 1_000_000))M" }
        if a >= 1_000 { return "$\(trim(v / 1_000))k" }
        return "$\(Int(v))"
    }
    private func trim(_ x: Double) -> String {
        let r = (x * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    private func row(_ label: String, _ amount: Money, emphasize: Bool = false, dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).fontWeight(emphasize ? .semibold : .regular)
            Spacer()
            MoneyText(amount, size: 16, color: Brand.clay)
                .fontWeight(emphasize ? .semibold : .regular)
        }
        .listRowBackground(Brand.surface)
    }
}
