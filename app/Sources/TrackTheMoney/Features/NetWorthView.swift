import SwiftUI
import TTMCore

struct NetWorthView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let nw = model.netWorth {
                        masthead(nw)
                        composition(nw)
                        breakdown(nw)
                    } else {
                        ProgressView("Loading…").padding(.top, 80)
                    }
                }
                .padding(20)
            }
            .background(Brand.paper.ignoresSafeArea())
            .inlineNavTitle("Track The Money")
            .refreshable { await model.refresh() }
        }
    }

    // The signature masthead: eyebrow → serif figure → trend.
    private func masthead(_ nw: NetWorthSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Net worth · as of \(Date(timeIntervalSince1970: TimeInterval(nw.asOf)).formatted(.dateTime.month(.abbreviated).day()))")
            MoneyText(nw.netWorth, size: 46, serif: true,
                      color: nw.netWorth.cents >= 0 ? Brand.ink : Brand.clay)
            if model.series.count > 1 {
                Sparkline(points: model.series)
                    .padding(.top, 2)
            }
        }
    }

    // Balance bar + legend.
    private func composition(_ nw: NetWorthSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            BalanceBar(assets: nw.assets, liabilities: nw.liabilities)
            HStack(alignment: .top) {
                legend("Assets", nw.assets, Brand.evergreen)
                Spacer()
                legend("Debts", nw.liabilities, Brand.clay, trailing: true)
            }
        }
        .brandCard()
    }

    private func legend(_ label: String, _ amount: Money, _ color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Eyebrow(label)
            }
            MoneyText(amount, size: 19, color: color)
        }
    }

    private func breakdown(_ nw: NetWorthSummary) -> some View {
        VStack(spacing: 0) {
            line("Liquid", nw.liquid, Brand.evergreen)
            sep; line("Investments", nw.investments, Brand.evergreen)
            sep; line("Real estate equity", nw.realEstateEquity, Brand.evergreen)
            sep; line("Secured debt", nw.securedDebt, Brand.clay)
            sep; line("Unsecured debt", nw.unsecuredDebt, Brand.clay)
        }
        .brandCard()
    }

    private var sep: some View { Rectangle().fill(Brand.hairline).frame(height: 1) }

    private func line(_ label: String, _ amount: Money, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 16)).foregroundStyle(Brand.ink)
            Spacer()
            MoneyText(amount, size: 16, color: color)
        }
        .padding(.vertical, 11)
    }
}
