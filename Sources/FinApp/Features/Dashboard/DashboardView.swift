import SwiftUI
import SwiftData
import Charts

/// Navigation value for the Net Worth detail page (so the Dashboard stack is
/// path-bound and can be reset on tab switch).
struct NetWorthRoute: Hashable {}

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

struct DashboardView: View {
    @Environment(AppRouter.self) private var router
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Category.name) private var categories: [Category]

    private let calendar = Calendar.current
    private var now: Date { Date() }
    @State private var path = NavigationPath()
    @State private var selectedTrendMonth: Date?
    @State private var showCategoryFilter = false
    /// Hide the synthetic "Uncategorized" row from the Spending Categories list.
    @AppStorage("dashHideUncategorized") private var hideUncategorized = false
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
            .overlay { trendPopupOverlay }
            .navigationTitle("Dashboard")
            .fixLargeTitleInset(trigger: topReset)
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

    /// Percent change over the trailing 30 days: latest snapshot vs. the most recent
    /// snapshot on or before 30 days ago. nil until we have that much history.
    private var delta: Double? {
        guard let last = snapshots.last else { return nil }
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        guard let baseline = snapshots.last(where: { $0.day <= cutoff }) else { return nil }
        let from = (baseline.value as NSDecimalNumber).doubleValue
        let to = (last.value as NSDecimalNumber).doubleValue
        guard from != 0 else { return nil }
        return (to - from) / abs(from)
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
            Text("30d")
                .foregroundStyle(Color.textSecondary)
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
        // Every non-hidden category shows, at $0 when there's no spend this month.
        var rows = Analytics.spendingCategories(transactions, categories: categories,
                                                inMonthOf: now, calendar: calendar)
        if hideUncategorized {
            rows.removeAll { $0.category == nil }
        } else if !rows.contains(where: { $0.category == nil }) {
            // Uncategorized is checked but had no spend this month — still show it at $0.
            rows.append(Analytics.CategoryTotal(category: nil, total: 0))
        }
        return rows
    }

    /// Guarded against divide-by-zero: with every category at $0 the max is 0.
    private var maxCategoryTotal: Decimal {
        let m = topCategories.map(\.total).max() ?? 0
        return m > 0 ? m : 1
    }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel("Spending Categories")
                Spacer()
                Button { showCategoryFilter = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("categoryFilterButton")
                .popover(isPresented: $showCategoryFilter) {
                    categoryFilterPopup
                        .presentationCompactAdaptation(.popover)
                }
            }
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

    /// Toggle which categories appear in the Spending Categories list. Tapping a
    /// row flips `isHidden` (SwiftData autosaves); the list updates live behind the
    /// popover, and tapping outside dismisses it.
    private var categoryFilterPopup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Show Categories")
            ScrollView {
                VStack(spacing: 4) {
                    let uncatVisible = !hideUncategorized
                    Button {
                        hideUncategorized.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.textSecondary)
                                .frame(width: 22)
                            Text("Uncategorized")
                                .foregroundStyle(Color.textPrimary)
                            Spacer(minLength: 16)
                            Image(systemName: uncatVisible ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(uncatVisible ? Color.brand : Color.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(uncatVisible ? Color.brand.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catToggle-Uncategorized")
                    ForEach(categories) { category in
                        let visible = !category.isHidden
                        Button {
                            category.isHidden.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.systemIcon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(hex: category.colorHex))
                                    .frame(width: 22)
                                Text(category.name)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer(minLength: 16)
                                Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(visible ? Color.brand : Color.textSecondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(visible ? Color.brand.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catToggle-\(category.name)")
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 260)
        .background(Color.surface)
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
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            // Capture the plot rect on tap only — measuring it every
                            // scroll frame via a preference re-rendered the whole
                            // dashboard and made scrolling stutter.
                            trendPlot = plotRect(proxy, geo)
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
