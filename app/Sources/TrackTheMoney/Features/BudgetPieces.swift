import SwiftUI
import TTMCore

// Shared pieces for the monthly budget screens (MONTHLY_BUDGET_PLAN.md D7).

extension Money {
    /// Whole dollars for budget figures ("$1,851"); cents add noise there.
    var dollars: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        let rounded = (Decimal(cents) / 100)
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "\(cents / 100)"
    }

    /// Parse what someone typed: "$1,200", "300.50", "45".
    init?(typed text: String) {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let m = Money(decimalString: cleaned), m.cents >= 0 else { return nil }
        self = m
    }

    /// Text for an editable field: "300" or "300.50".
    var fieldText: String {
        cents % 100 == 0 ? "\(cents / 100)" : "\(Decimal(cents) / 100)"
    }
}

enum BudgetText {
    static func day(_ t: UnixTime) -> String {
        Time.date(t).formatted(.dateTime.month(.abbreviated).day())
    }

    static func monthName(_ period: BudgetPeriod) -> String {
        Time.date(period.span.start).formatted(.dateTime.month(.wide))
    }

    /// Day of the month and days left, in local time.
    static func dayAndLeft(_ period: BudgetPeriod, now: Date = Date()) -> (day: Int, left: Int, total: Int) {
        let cal = Calendar.current
        let start = Time.date(period.span.start)
        let total = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let day = min(total, max(1, (cal.dateComponents([.day], from: start, to: now).day ?? 0) + 1))
        return (day, total - day, total)
    }
}

/// Spent against what's available, with a tick where an even pace would be today.
struct PlanBar: View {
    let spent: Money
    let available: Money
    let pace: Double
    var ahead = false
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = available.cents > 0 ? min(1, Double(spent.cents) / Double(available.cents)) : (spent.cents > 0 ? 1 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.ink.opacity(0.08))
                Capsule().fill(ahead ? Brand.clay : Brand.evergreen).frame(width: max(0, w * fill))
                Rectangle().fill(Brand.ink.opacity(0.55))
                    .frame(width: 2, height: height + 6)
                    .offset(x: max(0, min(w - 2, w * pace - 1)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(spent.dollars) of \(available.dollars)")
    }
}

/// The month split: bills, savings, spent, planned still to spend, splurge room.
struct MonthBar: View {
    struct Part: Identifiable {
        let id: String
        let label: String
        let amount: Money
        let color: Color
    }
    let parts: [Part]

    var body: some View {
        GeometryReader { geo in
            let shown = parts.filter { $0.amount.cents > 0 }
            let total = max(1, shown.reduce(Int64(0)) { $0 + $1.amount.cents })
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown) { part in
                    Rectangle().fill(part.color)
                        .frame(width: max(2, (geo.size.width - gaps) * CGFloat(part.amount.cents) / CGFloat(total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(parts.filter { $0.amount.cents > 0 }.map { "\($0.label) \($0.amount.dollars)" }.joined(separator: ", "))
    }
}

struct MonthBarLegend: View {
    let parts: [MonthBar.Part]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(parts.filter { $0.amount.cents > 0 }) { part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 8, height: 8)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Brand.hairline, lineWidth: 0.5))
                    Text("\(part.label) \(part.amount.dollars)").font(.caption).foregroundStyle(Brand.slate)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }
}

/// The last three months and this month so far, against the plan (dashed).
struct HistoryBars: View {
    let months: [(label: String, amount: Money, current: Bool)]
    let plan: Money

    var body: some View {
        let top = max(1, (months.map(\.amount.cents) + [plan.cents]).max() ?? 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let h = geo.size.height - 18
                ZStack(alignment: .bottom) {
                    // The plan line sits behind the bars, and the value labels have a
                    // background, so the line never strikes through a number.
                    if plan.cents > 0 {
                        Rectangle()
                            .stroke(Brand.brass, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(height: 1)
                            .offset(y: -h * CGFloat(plan.cents) / CGFloat(top))
                    }
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(Array(months.enumerated()), id: \.offset) { _, m in
                            VStack(spacing: 4) {
                                Text(m.amount.dollars).font(.caption).foregroundStyle(Brand.slate).lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 4)
                                    .background(Brand.surface, in: Capsule())
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(m.current ? Brand.evergreen.opacity(0.35) : Brand.evergreen.opacity(0.75))
                                    .frame(height: max(2, h * CGFloat(m.amount.cents) / CGFloat(top)))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(height: 150)
            HStack(spacing: 14) {
                ForEach(Array(months.enumerated()), id: \.offset) { _, m in
                    Text(m.label).font(.caption).foregroundStyle(Brand.slate).frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(months.map { "\($0.label) \($0.amount.dollars)" }.joined(separator: ", ") + "; plan \(plan.dollars)")
    }
}

/// A rounded card on the paper background, like the design's sections.
struct BudgetCard<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Eyebrow(title) }
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(Brand.slate) }
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
        }
    }
}
