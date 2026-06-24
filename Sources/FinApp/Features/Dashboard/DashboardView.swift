import SwiftUI
import SwiftData
import Charts

/// Navigation value for the Net Worth detail page (so the Dashboard stack is
/// path-bound and can be reset on tab switch).
struct NetWorthRoute: Hashable {}

/// Carries the trend chart's plot rect (in "dash" space) up to the Dashboard so
/// the value popup can be drawn on top of every other element.
private extension View {
    /// Fires `action` whenever the scroll view's vertical offset changes — used to
    /// dismiss the trend popup on scroll without a gesture that would fight the
    /// horizontal pager. No-op on iOS < 18 (no such device targets this app).
    @ViewBuilder
    func onTrendScroll(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in action() }
        } else {
            self
        }
    }
}

private struct TrendPlotKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct DashboardView: View {
    @Environment(AppRouter.self) private var router
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]

    private let calendar = Calendar.current
    private var now: Date { Date() }
    @State private var path = NavigationPath()
    @State private var selectedTrendMonth: Date?
    /// The trend chart's plot rectangle, in the "dash" coordinate space — used to
    /// position the popup and to map taps back to a bar.
    @State private var trendPlot: CGRect = .zero
    /// Bumped when this tab becomes active to rebuild the scroll view, which
    /// reliably lands at the very top (expanded title) — scrollTo only reaches the
    /// first item and is dropped mid-paging.
    @State private var topReset = 0
    @Environment(\.bottomBarInset) private var bottomBarInset

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if accounts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            heroCard
                            monthRow
                            if !topCategories.isEmpty { categoryCard }
                            trendCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .contentMargins(.bottom, bottomBarInset * 0.7, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    // Scrolling the page closes the trend popup. Observing the
                    // scroll offset (not a gesture) avoids interfering with the
                    // horizontal tab-paging swipe.
                    .onTrendScroll {
                        if selectedTrendMonth != nil { selectedTrendMonth = nil }
                    }
                    .id(topReset)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .coordinateSpace(name: "dash")
            .onPreferenceChange(TrendPlotKey.self) { trendPlot = $0 }
            .overlay { trendPopupOverlay }
            .navigationTitle("Dashboard")
            .navigationDestination(for: NetWorthRoute.self) { _ in NetWorthDetailView() }
        }
        // Switching away from this tab resets it to its root page. Only the active
        // tab owns `subpageOpen`, so an inactive tab's reset can't re-enable paging
        // while another tab has a detail open.
        .onChange(of: router.selectedTab) {
            selectedTrendMonth = nil
            if router.selectedTab == AppTab.dashboard.rawValue {
                router.subpageOpen = !path.isEmpty
                topReset += 1   // arriving → rebuild at the very top
            } else {
                path = NavigationPath()
            }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.dashboard.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    // MARK: Net worth hero

    private var netWorth: Decimal { Analytics.netWorth(accounts) }
    private var sparkValues: [Double] { snapshots.map { ($0.value as NSDecimalNumber).doubleValue } }

    /// Percent change from the first to the latest snapshot, when we have history.
    private var delta: Double? {
        guard let first = sparkValues.first, let last = sparkValues.last,
              sparkValues.count >= 2, first != 0 else { return nil }
        return (last - first) / abs(first)
    }

    private var heroCard: some View {
        NavigationLink(value: NetWorthRoute()) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Net worth")
                    Spacer()
                    if let delta { deltaChip(delta) }
                }
                MoneyText(value: netWorth, size: 40, weight: .bold,
                          color: netWorth < 0 ? .negative : .textPrimary)
                if sparkValues.count >= 2 {
                    Sparkline(values: sparkValues, tint: netWorth < 0 ? .negative : .brand)
                        .frame(height: 44)
                } else {
                    Text("History builds as you sync")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.surface)
                    .overlay(
                        LinearGradient(colors: [.brand.opacity(0.14), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("netWorthCard")
    }

    private func deltaChip(_ value: Double) -> some View {
        let up = value >= 0
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            Text(value.formatted(.percent.precision(.fractionLength(1))))
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(up ? Color.positive : Color.negative)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((up ? Color.positive : Color.negative).opacity(0.12), in: Capsule())
    }

    // MARK: This month

    private var monthRow: some View {
        HStack(spacing: 12) {
            monthCard("Income", Analytics.monthlyIncome(transactions, inMonthOf: now, calendar: calendar),
                      .positive) { router.showTransactions(.income) }
            monthCard("Spending", Analytics.monthlySpending(transactions, inMonthOf: now, calendar: calendar),
                      .negative) { router.showTransactions(.spending) }
        }
    }

    private func monthCard(_ label: String, _ value: Decimal, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    SectionLabel(label)
                }
                MoneyText(value: value, size: 22, weight: .semibold, color: color)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: Spending by category

    private var topCategories: [Analytics.CategoryTotal] {
        // Transfers move money between your own accounts — not real spending.
        Analytics.spendingByCategory(transactions, inMonthOf: now, calendar: calendar)
            .filter { $0.category?.name != "Transfers" }
    }

    private var maxCategoryTotal: Decimal { topCategories.map(\.total).max() ?? 1 }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Spending Categories")
            ForEach(topCategories) { item in
                let color = Color(hex: item.category?.colorHex ?? "#8E8E93")
                let name = item.category?.name ?? "Uncategorized"
                Button {
                    if let real = item.category?.name {
                        router.showTransactions(.category(real))
                    } else {
                        router.showTransactions(.uncategorized)
                    }
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: item.category?.systemIcon ?? "questionmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(color)
                                .frame(width: 22)
                            Text(name).foregroundStyle(Color.textPrimary)
                            Spacer()
                            MoneyText(value: item.total, size: 16, weight: .medium, color: .textSecondary)
                        }
                        shareBar(item.total, color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-\(name)")
            }
        }
        .cardStyle()
    }

    private func shareBar(_ total: Decimal, _ color: Color) -> some View {
        let fraction = max(0.04, NSDecimalNumber(decimal: total / maxCategoryTotal).doubleValue)
        return GeometryReader { geo in
            Capsule().fill(Color.hairline)
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: geo.size.width * fraction)
                }
        }
        .frame(height: 4)
    }

    // MARK: Trend

    private var trend: [Analytics.MonthPoint] {
        Analytics.monthlyTrend(transactions, endingIn: now, count: 6, calendar: calendar)
    }

    private var selectedPoint: Analytics.MonthPoint? {
        guard let m = selectedTrendMonth else { return nil }
        return trend.first { calendar.isDate($0.month, equalTo: m, toGranularity: .month) }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("6-month trend")
            Chart {
                ForEach(trend) { point in
                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Income", (point.income as NSDecimalNumber).doubleValue)
                    )
                    .position(by: .value("Type", "Income"))
                    .foregroundStyle(by: .value("Type", "Income"))
                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Spending", (point.spending as NSDecimalNumber).doubleValue)
                    )
                    .position(by: .value("Type", "Spending"))
                    .foregroundStyle(by: .value("Type", "Spending"))
                }
                if let point = selectedPoint {
                    RuleMark(x: .value("Month", point.month, unit: .month))
                        .foregroundStyle(Color.textSecondary.opacity(0.35))
                }
            }
            .chartForegroundStyleScale(["Income": Color.positive, "Spending": Color.negative])
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel().foregroundStyle(Color.textSecondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // Report the plot rect in "dash" space so the popup can sit on
                    // top of everything, outside the chart's clip.
                    Color.clear
                        .preference(key: TrendPlotKey.self, value: plotRect(proxy, geo))
                        .contentShape(Rectangle())
                        // Opens the popup; while open, the full-screen catcher below
                        // intercepts taps (switch bar / dismiss) instead.
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            selectTrendBar(atX: x, using: proxy)
                        }
                }
            }
            .frame(height: 170)
            .accessibilityIdentifier("trendChart")
        }
        .cardStyle()
    }

    private func trendPopup(_ point: Analytics.MonthPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(point.month, format: .dateTime.month(.abbreviated).year())
                .font(.caption2.weight(.semibold)).foregroundStyle(Color.textSecondary)
            popupRow("Income", point.income, .positive)
            popupRow("Spending", point.spending, .negative)
        }
        .padding(8)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("trendPopup")
    }

    private func popupRow(_ label: String, _ value: Decimal, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(Color.textPrimary)
            Spacer(minLength: 14)
            MoneyText(value: value, size: 12, weight: .semibold, color: color)
        }
    }

    /// The chart's plot rect translated into the "dash" coordinate space.
    private func plotRect(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect {
        guard let anchor = proxy.plotFrame else { return .zero }
        let local = geo[anchor]
        let frame = geo.frame(in: .named("dash"))
        return CGRect(x: frame.minX + local.minX, y: frame.minY + local.minY,
                      width: local.width, height: local.height)
    }

    private func selectTrendBar(atX x: CGFloat, using proxy: ChartProxy) {
        guard let date: Date = proxy.value(atX: x, as: Date.self),
              let month = calendar.dateInterval(of: .month, for: date)?.start else { return }
        toggleTrendMonth(month)
    }

    private func toggleTrendMonth(_ month: Date) {
        if let sel = selectedTrendMonth, calendar.isDate(sel, equalTo: month, toGranularity: .month) {
            selectedTrendMonth = nil
        } else {
            selectedTrendMonth = month
        }
    }

    /// Floats the value popup above all chart elements. It never intercepts
    /// touches (so the page still scrolls); tapping a bar switches/closes it and
    /// scrolling closes it (see the scroll-offset handler on the scroll view).
    @ViewBuilder
    private var trendPopupOverlay: some View {
        if let point = selectedPoint, trendPlot != .zero {
            trendPopup(point)
                .fixedSize()
                .position(popupPosition(for: point))
                .allowsHitTesting(false)
        }
    }

    private func popupPosition(for point: Analytics.MonthPoint) -> CGPoint {
        let count = max(trend.count, 1)
        let idx = trend.firstIndex { calendar.isDate($0.month, equalTo: point.month, toGranularity: .month) } ?? 0
        let x = trendPlot.minX + (CGFloat(idx) + 0.5) / CGFloat(count) * trendPlot.width
        let clampedX = min(max(x, trendPlot.minX + 54), trendPlot.maxX - 54)
        return CGPoint(x: clampedX, y: trendPlot.minY - 34)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.brand)
            Text("No data yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Connect SimpleFin in Settings to see your net worth and spending.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textSecondary)
        }
        .cardStyle(padding: 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
