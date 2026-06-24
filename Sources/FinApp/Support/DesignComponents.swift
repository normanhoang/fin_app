import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Screen background

/// Inset (≈ floating tab bar height + gap) that scroll views add to their bottom
/// content so the last row clears the bar. Set once in RootView.
struct BottomBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

private struct ScreenBackground: ViewModifier {
    @Environment(\.bottomBarInset) private var bottomInset
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .background(Color.appBackground.ignoresSafeArea())
    }
}

extension View {
    /// Charcoal app background behind a List/ScrollView, hiding the system grouped
    /// fill, plus bottom room so content clears the floating tab bar.
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

// MARK: - Chip

/// Small rounded label used for account types, cadences, and subtotals.
struct Chip: View {
    let text: String
    var color: Color = .textSecondary
    init(_ text: String, color: Color = .textSecondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Brand mark

/// The app's logo: a mint upward trend line on a dark rounded tile. Reused on the
/// splash screen; the same shape backs the app icon.
struct BrandMark: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#1A1D22"), Color(hex: "#0E0F11")],
                                     startPoint: .top, endPoint: .bottom))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let pts = [CGPoint(x: 0.16, y: 0.72), CGPoint(x: 0.40, y: 0.50),
                           CGPoint(x: 0.58, y: 0.60), CGPoint(x: 0.84, y: 0.26)]
                    .map { CGPoint(x: $0.x * w, y: $0.y * h) }
                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Color.brand, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
                .shadow(color: .brand.opacity(0.55), radius: size * 0.05)
                Circle().fill(Color.brand)
                    .frame(width: size * 0.11, height: size * 0.11)
                    .position(pts.last!)
            }
            .padding(size * 0.18)
        }
        .frame(width: size, height: size)
    }
}

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
