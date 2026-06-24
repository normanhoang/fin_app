import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppRouter.self) private var router
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]

    private let calendar = Calendar.current
    private var now: Date { Date() }

    var body: some View {
        NavigationStack {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No Data Yet",
                    systemImage: "chart.pie",
                    description: Text("Connect SimpleFin in Settings to see your net worth and spending.")
                )
                .navigationTitle("Dashboard")
            } else {
                List {
                    netWorthSection
                    monthSummarySection
                    if !topCategories.isEmpty { categorySection }
                    trendSection
                }
                .navigationTitle("Dashboard")
                .refreshable { await coordinator.sync() }
            }
        }
    }

    private var netWorthSection: some View {
        Section {
            NavigationLink {
                NetWorthDetailView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Net Worth").font(.subheadline).foregroundStyle(.secondary)
                    Text(Money.string(Analytics.netWorth(accounts)))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("netWorthCard")
        }
    }

    private var monthSummarySection: some View {
        Section("This Month") {
            HStack {
                Button {
                    show(.income)
                } label: {
                    stat("Income", Analytics.monthlyIncome(transactions, inMonthOf: now, calendar: calendar), .green)
                }
                .buttonStyle(.plain)
                Divider()
                Button {
                    show(.spending)
                } label: {
                    stat("Spending", Analytics.monthlySpending(transactions, inMonthOf: now, calendar: calendar), .red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stat(_ label: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Money.string(value)).font(.headline).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var topCategories: [Analytics.CategoryTotal] {
        Array(Analytics.spendingByCategory(transactions, inMonthOf: now, calendar: calendar).prefix(6))
    }

    private var categorySection: some View {
        Section("Spending by Category") {
            ForEach(topCategories) { item in
                Button {
                    if let name = item.category?.name { show(.category(name)) }
                } label: {
                    HStack {
                        Image(systemName: item.category?.systemIcon ?? "questionmark.circle")
                            .foregroundStyle(Color(hex: item.category?.colorHex ?? "#8E8E93"))
                            .frame(width: 28)
                        Text(item.category?.name ?? "Uncategorized")
                        Spacer()
                        Text(Money.string(item.total)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-\(item.category?.name ?? "Uncategorized")")
            }
        }
    }

    private var trend: [Analytics.MonthPoint] {
        Analytics.monthlyTrend(transactions, endingIn: now, count: 6, calendar: calendar)
    }

    private var trendSection: some View {
        Section("6-Month Trend") {
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
            .chartForegroundStyleScale(["Income": Color.green, "Spending": Color.red])
            .frame(height: 160)
            .padding(.vertical, 4)
        }
    }

    private func show(_ filter: TransactionFilter) {
        router.txnFilter = filter
        router.selectedTab = 2
    }
}
