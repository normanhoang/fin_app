import SwiftUI
import Charts

// MARK: - Card

/// Quiet Capital surface: rounded charcoal panel with a hairline edge.
private struct CardStyle: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = 18) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

// MARK: - Money text

/// Currency figure in SF Rounded — the app's signature numeric treatment.
struct MoneyText: View {
    let value: Decimal
    var code: String = "USD"
    var size: CGFloat = 17
    var weight: Font.Weight = .semibold
    var color: Color = .textPrimary

    var body: some View {
        Text(Money.string(value, code: code))
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

// MARK: - Section label

/// Small uppercase tracked header used inside cards.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.textSecondary)
    }
}

// MARK: - Sparkline

/// Compact trend line with a soft area fill. Renders nothing useful below 2 points.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .brand

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            LineMark(x: .value("i", index), y: .value("v", value))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
            AreaMark(x: .value("i", index), y: .value("v", value))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(
                    colors: [tint.opacity(0.25), tint.opacity(0.01)],
                    startPoint: .top, endPoint: .bottom
                ))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
