import SwiftUI
import SwiftData
import Charts

/// Navigation value for the Net Worth detail page (so the Dashboard stack is
/// path-bound and can be reset on tab switch).
struct NetWorthRoute: Hashable {}

struct DashboardView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppRouter.self) private var router
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]

    private let calendar = Calendar.current
    private var now: Date { Date() }
    @State private var path = NavigationPath()
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
                    .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Dashboard")
            .navigationDestination(for: NetWorthRoute.self) { _ in NetWorthDetailView() }
            .refreshable { await coordinator.sync() }
        }
        // Switching away from this tab resets it to its root page.
        .onChange(of: router.selectedTab) { if router.selectedTab != 0 { path = NavigationPath() } }
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

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("6-month trend")
            Chart(trend) { point in
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
            .frame(height: 170)
        }
        .cardStyle()
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
