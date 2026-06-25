import SwiftUI
import TTMCore

// "The Statement" design system. Color is structural: assets are cool
// (evergreen), debts are warm (clay) — the same mapping everywhere.
enum Brand {
    static let paper      = Color(hex: 0xF4F6F2)
    static let surface    = Color(hex: 0xFCFDFB)
    static let ink        = Color(hex: 0x16211C)
    static let evergreen  = Color(hex: 0x1E4D3A)   // assets / positive / brand
    static let clay       = Color(hex: 0xB0533C)   // debts / interest / negative
    static let brass      = Color(hex: 0x9A7B3F)   // signature accent (used sparingly)
    static let slate      = Color(hex: 0x6A746E)   // secondary text
    static let hairline   = Color(hex: 0x16211C).opacity(0.10)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension Font {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Uppercase, tracked label — the recurring structural device.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption, design: .default).weight(.semibold))
            .tracking(1.6)
            .foregroundStyle(Brand.slate)
    }
}

/// Money in tabular figures. Serif for hero figures, SF otherwise.
struct MoneyText: View {
    let money: Money
    var size: CGFloat = 17
    var serif = false
    var color: Color = Brand.ink
    var currency = "USD"
    init(_ money: Money, size: CGFloat = 17, serif: Bool = false, color: Color = Brand.ink, currency: String = "USD") {
        self.money = money; self.size = size; self.serif = serif; self.color = color; self.currency = currency
    }
    var body: some View {
        Text(money.formatted(currencyCode: currency))
            .font(serif ? .serif(size) : .system(size: size, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// Signature element: one bar splitting assets (evergreen) vs debts (clay).
struct BalanceBar: View {
    let assets: Money
    let liabilities: Money
    var body: some View {
        GeometryReader { geo in
            let total = max(1.0, Double(assets.cents) + Double(liabilities.cents))
            let assetW = geo.size.width * (Double(assets.cents) / total)
            HStack(spacing: 3) {
                Capsule().fill(Brand.evergreen).frame(width: max(0, assetW))
                Capsule().fill(Brand.clay)
            }
        }
        .frame(height: 12)
    }
}

/// Minimal hairline trend line for the net-worth series.
struct Sparkline: View {
    let points: [NetWorthPoint]
    var body: some View {
        GeometryReader { geo in
            let values = points.map { Double($0.netWorth.cents) }
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let span = max(1.0, hi - lo)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * Double(i) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (v - lo) / span)
                        let pt = CGPoint(x: x, y: y)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                }
                .stroke(Brand.evergreen, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 46)
    }
}

extension View {
    /// Small inline title on iOS (so a hero can lead); plain title on macOS.
    func inlineNavTitle(_ title: String) -> some View {
        #if os(iOS)
        return navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        return navigationTitle(title)
        #endif
    }

    func brandCard() -> some View {
        padding(18)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
    }

    /// Brand paper surface + hidden default scroll background, applied per screen.
    func statementBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Brand.paper.ignoresSafeArea())
    }
}
