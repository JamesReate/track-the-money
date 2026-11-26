import SwiftUI
import Charts
import TTMCore

struct DebtInterestView: View {
    @Bindable var model: AppModel
    @State private var range: DebtRange = .all
    @State private var settingRate: AccountSummary?

    /// Debt accounts, highest rate first (unset rates last): the order to pay
    /// them down in if you're minimizing interest. Uses the rate that applies
    /// now, so a card on a 0% promo sorts by 0%.
    private var debts: [AccountSummary] {
        model.accounts.filter { $0.accountClass.isDebt && $0.status.counts }.sorted {
            switch ($0.effectiveAprBps, $1.effectiveAprBps) {
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
        let rated = debts.compactMap { d in d.effectiveAprBps.map { (abs(d.balance.cents), Int64($0)) } }
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
                if let outlook = model.promoOutlook, !outlook.payoffs.isEmpty { promoPayoffs(outlook) }
                if let interest = model.interest, !interest.byAccount.isEmpty {
                    Section {
                        ForEach(keyed("paid", interest.byAccount.map { ($0.accountId, $0) }), id: \.key) { _, line in
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
            ForEach(keyed("rate", debts.map { ($0.id, $0) }), id: \.key) { _, debt in
                Button { settingRate = debt } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(debt.name).foregroundStyle(Brand.ink).lineLimit(1)
                            MoneyText(Money(cents: abs(debt.balance.cents)), size: 13, color: Brand.slate,
                                      currency: debt.currency)
                        }
                        Spacer()
                        if let promo = debt.activePromo {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(APR.format(promo.aprBps)).font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Brand.brass)
                                Text("until \(APR.day(promo.endsOn))" + (debt.aprBps.map { ", then \(APR.format($0))" } ?? ""))
                                    .font(.caption).foregroundStyle(Brand.slate)
                            }
                        } else if let apr = debt.aprBps {
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
        footer: { Text("Highest rate first, using promo rates while they last. Tap a debt to set its APR or a card's promo.") }
    }

    /// Can liquid cash clear each promo balance before its rate jumps? Cash is
    /// applied to the earliest deadline first (PROMO_APR_PLAN D3).
    private func promoPayoffs(_ outlook: PromoOutlook) -> some View {
        Section {
            HStack {
                Text("Cash on hand").foregroundStyle(Brand.slate)
                Spacer()
                MoneyText(outlook.liquid, size: 15, color: Brand.evergreen)
            }
            .listRowBackground(Brand.surface)
            ForEach(keyed("promo", outlook.payoffs.map { ($0.id, $0) }), id: \.key) { _, p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.accountName).foregroundStyle(Brand.ink).lineLimit(1)
                        Spacer()
                        MoneyText(p.balance, size: 15, color: Brand.clay)
                    }
                    Text("\(APR.format(p.promo.aprBps)) ends \(APR.day(p.promo.endsOn)) · \(p.daysLeft) day\(p.daysLeft == 1 ? "" : "s") left")
                        .font(.caption).foregroundStyle(Brand.slate)
                    HStack(spacing: 6) {
                        // An HStack, not a Label: List rows pad a Label's icon into its own column.
                        HStack(spacing: 4) {
                            Image(systemName: p.covered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            Text(p.covered ? "Cash covers it" : "Short \(p.shortfall.formatted())")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(p.covered ? Brand.evergreen : Brand.clay)
                        Spacer()
                        Text("\(p.monthlyToClear.formatted())/mo to clear")
                            .font(.caption).foregroundStyle(Brand.ink)
                    }
                    if let after = p.interestPerMonthAfter, let regular = p.regularAprBps {
                        Text("If it isn’t paid off: about \(after.formatted())/mo in interest at \(APR.format(regular)).")
                            .font(.caption).foregroundStyle(Brand.slate)
                    } else {
                        Text("Set the regular rate to see what it costs after the promo.")
                            .font(.caption).foregroundStyle(Brand.slate)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Brand.surface)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("promo-\(p.accountName)")
            }
        } header: { Eyebrow("Promo payoffs") }
        footer: {
            Text(outlook.shortfall == .zero
                 ? "Your liquid accounts hold enough to clear every promo balance before it ends, earliest first. That would use \(outlook.totalDue.formatted()) of \(outlook.liquid.formatted()), before any other bills."
                 : "Liquid cash falls \(outlook.shortfall.formatted()) short of clearing every promo balance before it ends. Paying the monthly amounts above avoids the regular rate.")
        }
    }

    /// Rows keyed per section. One account appears in several sections of this
    /// List (rates, promo payoffs, interest paid); with bare account ids the
    /// macOS List reuses one section's row in another, so the Visa's rate row
    /// rendered as its interest-paid row and couldn't be tapped.
    private func keyed<T>(_ section: String, _ rows: [(String, T)]) -> [(key: String, value: T)] {
        rows.map { (key: "\(section)-\($0.0)", value: $0.1) }
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
