import SwiftUI
import SwiftData
import Charts

/// Navigation value for the Net Worth detail page (so the Dashboard stack is
/// path-bound and can be reset on tab switch).
struct NetWorthRoute: Hashable {}

private extension View {
    /// Fires `action` whenever the scroll view's vertical offset changes — used to
    /// dismiss the trend popup on scroll without a gesture that would fight the
    /// horizontal pager. iOS 17 uses a simultaneous vertical-drag fallback.
    @ViewBuilder
    func onTrendScroll(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in action() }
        } else {
            simultaneousGesture(
                DragGesture(minimumDistance: 2).onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) { action() }
                }
            )
        }
    }
}

struct DashboardView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var bills: [RecurringBill]
    @Query private var budgets: [Budget]

    private let calendar = Calendar.current
    private var now: Date { Date() }
    @State private var path = NavigationPath()
    @State private var selectedTrendMonth: Date?
    @State private var showCategoryFilter = false
    @State private var showBudgetsSheet = false
    @State private var showAddBudget = false
    /// Hide the synthetic "Uncategorized" row from the Spending Categories list.
    @AppStorage("dashHideUncategorized") private var hideUncategorized = false
    /// Auto mode: show only categories with real spend this month; the manual
    /// isHidden flags lie dormant. Defaults on for fresh and existing installs.
    @AppStorage("dashCategoryAuto") private var autoCategories = true
    /// The trend chart's plot rectangle, in the "dash" coordinate space — used to
    /// position the popup and to map taps back to a bar.
    @State private var trendPlot: CGRect = .zero
    /// Bumped when this tab becomes active to rebuild the scroll view, which
    /// reliably lands at the very top (expanded title) — scrollTo only reaches the
    /// first item and is dropped mid-paging.
    @State private var topReset = 0
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Environment(\.scenePhase) private var scenePhase

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
                            triageChip
                            budgetsCard
                            if !categories.isEmpty { categoryCard }
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
        // The popover presents above the window's content, so the privacy cover
        // and lock screen (ZStack overlays in FinAppApp) can't hide it — dismiss
        // it the moment the scene stops being frontmost.
        .onChange(of: scenePhase) {
            if scenePhase != .active { showCategoryFilter = false }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.dashboard.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    // MARK: Net worth hero

    private var netWorth: Decimal { Analytics.netWorth(accounts) }
    private var sparkValues: [Double] { snapshots.map { ($0.value as NSDecimalNumber).doubleValue } }

    /// Trailing 30-day net-worth change (falls back to full history when younger
    /// than 30 days). Carries the actual span so the chip can label it honestly.
    private var delta: (percent: Double, days: Int)? {
        Analytics.recentChange(snapshots, asOf: now, calendar: calendar)
    }

    private var heroCard: some View {
        NavigationLink(value: NetWorthRoute()) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Net worth")
                    Spacer()
                    if let delta { deltaChip(delta.percent, days: delta.days) }
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
                Divider().overlay(Color.hairline)
                safeToSpendRow
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

    private func deltaChip(_ value: Double, days: Int) -> some View {
        let up = value >= 0
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            Text(value.formatted(.percent.precision(.fractionLength(1))))
            Text(days >= 30 ? "30d" : "\(days)d")
                .foregroundStyle(Color.textSecondary)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(up ? Color.positive : Color.negative)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((up ? Color.positive : Color.negative).opacity(0.12), in: Capsule())
    }

    // MARK: Safe to spend

    private var safeToSpendRow: some View {
        let amount = Analytics.safeToSpend(transactions, bills: bills, asOf: now, calendar: calendar)
        let until = calendar.dateInterval(of: .month, for: now)?.end
            .formatted(.dateTime.month(.abbreviated).day()) ?? ""
        return HStack {
            (Text("Safe to spend").foregroundStyle(Color.textSecondary)
                + Text(" · until \(until)").foregroundStyle(Color.textTertiary))
                .font(.system(size: 13))
            Spacer()
            MoneyText(value: amount, size: 16, weight: .semibold,
                      color: amount < 0 ? .negative : .brand)
        }
        .accessibilityIdentifier("safeToSpendRow")
    }

    // MARK: This month

    private var monthRow: some View {
        let incomeDelta = Analytics.monthOverMonthChange(.income, txns: transactions,
                                                         asOf: now, calendar: calendar)
        let spendingDelta = Analytics.monthOverMonthChange(.spending, txns: transactions,
                                                           asOf: now, calendar: calendar)
        return HStack(alignment: .top, spacing: 12) {
            monthCard("Income", Analytics.monthlyIncome(transactions, inMonthOf: now, calendar: calendar),
                      amountColor: .positive, delta: incomeDelta,
                      deltaColor: .textSecondary) { router.showTransactions(.income) }
            // A spending drop is the good direction — that delta earns green.
            monthCard("Spending", Analytics.monthlySpending(transactions, inMonthOf: now, calendar: calendar),
                      amountColor: .textPrimary, delta: spendingDelta,
                      deltaColor: (spendingDelta ?? 0) < 0 ? .positive : .textSecondary) {
                router.showTransactions(.spending)
            }
        }
    }

    private func monthCard(_ label: String, _ value: Decimal, amountColor: Color,
                           delta: Double?, deltaColor: Color,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(label)
                MoneyText(value: value, size: 20, weight: .bold, color: amountColor)
                if let delta {
                    Text(deltaLine(delta))
                        .font(.system(size: 11.5))
                        .foregroundStyle(deltaColor)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    /// "+4% vs Jun" / "−8% vs Jun".
    private func deltaLine(_ change: Double) -> String {
        let percent = abs(change).formatted(.percent.precision(.fractionLength(0)))
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)?
            .formatted(.dateTime.month(.abbreviated)) ?? ""
        return "\(change < 0 ? "−" : "+")\(percent) vs \(lastMonth)"
    }

    // MARK: Uncategorized triage

    @ViewBuilder
    private var triageChip: some View {
        let count = Analytics.uncategorizedCount(transactions, inMonthOf: now, calendar: calendar)
        if count > 0 {
            Button { router.showTriage = true } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.brand.opacity(0.12))
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brand)
                    }
                    .frame(width: 26, height: 26)
                    Text("Review \(count) uncategorized")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("uncategorizedChip")
        }
    }

    // MARK: Budgets

    /// Non-income categories that don't already have a budget — what the add form
    /// offers (mirrors BudgetsView's own filter).
    private var budgetableCategories: [Category] {
        let taken = Set(budgets.compactMap { $0.category?.name })
        return categories.filter { !$0.isIncome && !taken.contains($0.name) }
    }

    @ViewBuilder
    private var budgetsCard: some View {
        // Each branch owns its own single sheet — two `.sheet` modifiers on one
        // view present unreliably in SwiftUI.
        if budgets.isEmpty {
            emptyBudgetsCard
                .sheet(isPresented: $showAddBudget) { AddBudgetView(categories: budgetableCategories) }
        } else {
            populatedBudgetsCard
                .sheet(isPresented: $showBudgetsSheet) { BudgetsView() }
        }
    }

    private var populatedBudgetsCard: some View {
        // Up to 6 budgets shown on the card, laid out three per row.
        let rows: [(budget: Budget, spent: Decimal)] = budgets.prefix(6).map { budget in
            (budget, budget.category.map {
                Analytics.spending(for: $0, in: transactions, inMonthOf: now, calendar: calendar)
            } ?? 0)
        }
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start
        let overBudget = rows.filter {
            $0.spent > $0.budget.monthlyLimit && $0.budget.overBudgetDismissedMonth != monthStart
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Budgets")
                Spacer()
                Button("Edit") { showBudgetsSheet = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("budgetsEditButton")
            }
            ringRow(Array(rows.prefix(3)))
            if rows.count > 3 {
                ringRow(Array(rows.dropFirst(3)))
            }
            ForEach(overBudget, id: \.budget.id) { row in
                overBudgetCallout(row.budget, spent: row.spent) {
                    row.budget.overBudgetDismissedMonth = monthStart
                    try? context.save()
                }
            }
        }
        .cardStyle()
        // No container identifier: it propagates onto children and clobbers the
        // Edit button's id in the AX tree (only leaf controls get ids).
    }

    /// A three-up row of budget rings. Each ring occupies exactly one third of the
    /// width, and the row is centered — so a partial row of one or two rings sits
    /// centered rather than pinned left, matching the row above. Fonts are fixed
    /// size, so the row height is deterministic.
    private func ringRow(_ items: [(budget: Budget, spent: Decimal)]) -> some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - 24) / 3 // two 12pt gaps
            HStack(spacing: 12) {
                ForEach(items, id: \.budget.id) { row in
                    budgetRing(row.budget, spent: row.spent)
                        .frame(width: columnWidth)
                }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 116)
    }

    /// Shown when no budgets exist so the feature stays reachable from the Dashboard.
    private var emptyBudgetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Budgets")
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.brand.opacity(0.12))
                    Image(systemName: "chart.bar")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.brand)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set a monthly budget")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Text("Track spending by category")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
            Button { showAddBudget = true } label: {
                Text("Add budget")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addBudgetButton")
        }
        .cardStyle()
        // No container identifier: it propagates onto children and clobbers the
        // Add button's id in the AX tree (only leaf controls get ids).
    }

    private func budgetRing(_ budget: Budget, spent: Decimal) -> some View {
        let limit = (budget.monthlyLimit as NSDecimalNumber).doubleValue
        let fraction = limit > 0 ? (spent as NSDecimalNumber).doubleValue / limit : 0
        let over = spent > budget.monthlyLimit
        let tint: Color = over ? .negative : .brand
        let whole = Decimal.FormatStyle.Currency.currency(code: "USD").precision(.fractionLength(0))
        return Button {
            if let name = budget.category?.name { router.showTransactions(.category(name)) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.hairline, lineWidth: 6)
                    Circle().trim(from: 0, to: min(fraction, 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(over ? Color.negative : Color.textPrimary)
                }
                .frame(width: 64, height: 64)
                Text(budget.category?.name ?? "—")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text("\(spent.formatted(whole)) of \(budget.monthlyLimit.formatted(whole))")
                    .font(.system(size: 12))
                    .foregroundStyle(over ? Color.negative : Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("budgetRing-\(budget.category?.name ?? "none")")
    }

    private func overBudgetCallout(_ budget: Budget, spent: Decimal,
                                   onDismiss: @escaping () -> Void) -> some View {
        let overBy = (spent - budget.monthlyLimit)
            .formatted(.currency(code: "USD").precision(.fractionLength(0)))
        let daysLeft = calendar.dateInterval(of: .month, for: now).map {
            calendar.dateComponents([.day], from: now, to: $0.end).day ?? 0
        } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.negative)
            (Text("\(budget.category?.name ?? "A budget") is ").foregroundStyle(Color.textSecondary)
                + Text("\(overBy) over").fontWeight(.semibold).foregroundStyle(Color.negative)
                + Text(" with \(daysLeft) days left").foregroundStyle(Color.textSecondary))
                .font(.system(size: 13))
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(5)
                    .background(Color.negative.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss over-budget alert")
            .accessibilityIdentifier("dismissOverBudget-\(budget.category?.name ?? "none")")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.negative.opacity(0.25), lineWidth: 1))
    }

    // MARK: Spending by category

    private func topCategories(from monthSpend: [Analytics.CategoryTotal]) -> [Analytics.CategoryTotal] {
        if autoCategories {
            // Auto: only categories with spend this month. spendingByCategory
            // ignores isHidden (wanted — manual hides are dormant) but includes
            // Transfers, so strip them here. Re-sort with the name tiebreak:
            // its dictionary-built order is unstable on total ties.
            return monthSpend
                .filter { $0.category?.name != "Transfers" && $0.total > 0 }
                .sorted {
                    $0.total != $1.total ? $0.total > $1.total
                                         : ($0.category?.name ?? "") < ($1.category?.name ?? "")
                }
        }
        // Transfers move money between your own accounts — not real spending.
        // Every non-hidden category shows, at $0 when there's no spend this month.
        var rows = Analytics.spendingCategories(spent: monthSpend, categories: categories)
        if hideUncategorized {
            rows.removeAll { $0.category == nil }
        } else if !rows.contains(where: { $0.category == nil }) {
            // Uncategorized is checked but had no spend this month — still show it at $0.
            rows.append(Analytics.CategoryTotal(category: nil, total: 0))
        }
        return rows
    }

    private var categoryCard: some View {
        // Compute the totals once per render and hand them down — recomputing the
        // full aggregation for the max and again per row multiplied the work.
        // One transaction scan shared by the category list and the filter popup.
        let monthSpend = Analytics.spendingByCategory(transactions, inMonthOf: now, calendar: calendar)
        let cats = topCategories(from: monthSpend)
        let monthTotal = cats.reduce(Decimal(0)) { $0 + max($1.total, 0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Spending Categories")
                Spacer()
                Text(now.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                Button { showCategoryFilter = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter categories")
                .accessibilityIdentifier("categoryFilterButton")
            }
            .popover(isPresented: $showCategoryFilter) {
                categoryFilterPopup(monthSpend: monthSpend)
                    .presentationCompactAdaptation(.popover)
            }
            if monthTotal > 0 {
                stackedShareBar(cats, monthTotal: monthTotal)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
            ForEach(cats) { item in
                let color = Color(hex: item.category?.colorHex ?? "#8E8E93")
                let name = item.category?.name ?? "Uncategorized"
                Button {
                    if let real = item.category?.name {
                        router.showTransactions(.category(real))
                    } else {
                        router.showTransactions(.uncategorized)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(color.opacity(0.14))
                            Image(systemName: item.category?.systemIcon ?? "questionmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(color)
                        }
                        .frame(width: 32, height: 32)
                        Text(name)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        MoneyText(value: item.total, size: 15, weight: .semibold, color: .textPrimary)
                        Text(percentLabel(item.total, of: monthTotal))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-\(name)")
            }
            if cats.isEmpty {
                Text(autoCategories ? "No spending yet this month."
                                    : "All categories hidden — tap the filter to show some.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .cardStyle()
    }

    /// One 8pt pill, a segment per spent category butted edge-to-edge, width ∝
    /// share of month spend. The whole bar is clipped to a single capsule so it
    /// reads as one pill rather than separate chips.
    private func stackedShareBar(_ cats: [Analytics.CategoryTotal], monthTotal: Decimal) -> some View {
        GeometryReader { geo in
            let spent = cats.filter { $0.total > 0 }
            let totalD = (monthTotal as NSDecimalNumber).doubleValue
            HStack(spacing: 0) {
                ForEach(spent) { item in
                    Color(hex: item.category?.colorHex ?? "#8E8E93")
                        .frame(width: max(3, geo.size.width * CGFloat((item.total as NSDecimalNumber).doubleValue / totalD)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func percentLabel(_ total: Decimal, of monthTotal: Decimal) -> String {
        guard monthTotal > 0, total > 0 else { return "0%" }
        let fraction = ((total / monthTotal) as NSDecimalNumber).doubleValue
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// This-month spend keyed by category name (uncategorized under ""). Flags
    /// hidden categories that still had real spend this month.
    private func monthSpendByName(from monthSpend: [Analytics.CategoryTotal]) -> [String: Decimal] {
        var map: [String: Decimal] = [:]
        for t in monthSpend {
            map[t.category?.name ?? ""] = t.total
        }
        return map
    }

    /// Leaving Auto via a popup tap must not change what's visible: seed the
    /// manual flags from Auto's current view (visible = has spend), then let
    /// the tapped toggle apply on top. No-op when Auto is already off.
    private func disableAutoSeedingFromSpend(spend: [String: Decimal]) {
        guard autoCategories else { return }
        for category in categories where !category.isIncome && category.name != "Transfers" {
            category.isHidden = (spend[category.name] ?? 0) <= 0
        }
        hideUncategorized = (spend[""] ?? 0) <= 0
        autoCategories = false
    }

    /// Filter checkbox: filled when shown, half-filled when hidden but the category
    /// still has spend this month, empty when hidden with no spend.
    /// SF Symbols quirk: `circle.tophalf.filled` renders with the BOTTOM half solid
    /// (and vice versa) — this is the bottom-solid look, verified by rendering.
    private func filterCheckbox(visible: Bool, hasSpend: Bool) -> some View {
        let name = visible ? "checkmark.circle.fill" : (hasSpend ? "circle.tophalf.filled" : "circle")
        return Image(systemName: name)
            .foregroundStyle(visible || hasSpend ? Color.brand : Color.textSecondary)
    }

    /// Toggle which categories appear in the Spending Categories list. Tapping a
    /// row flips `isHidden` (SwiftData autosaves); the list updates live behind the
    /// popover, and tapping outside dismisses it. Income categories and Transfers
    /// are omitted — the same exclusions the list itself applies, so every row
    /// here is one that can actually appear.
    private func categoryFilterPopup(monthSpend: [Analytics.CategoryTotal]) -> some View {
        let listed = categories.filter { !$0.isIncome && $0.name != "Transfers" }
        let spend = monthSpendByName(from: monthSpend)
        // Rows show EFFECTIVE visibility: under Auto that's "has spend", not the
        // dormant isHidden flags. Any tap seeds the flags from this view first
        // (so nothing jumps), turns Auto off, then applies the toggle.
        let uncatVisible = autoCategories ? (spend[""] ?? 0) > 0 : !hideUncategorized
        let allVisible = uncatVisible && listed.allSatisfy {
            autoCategories ? (spend[$0.name] ?? 0) > 0 : !$0.isHidden
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Show Categories")
                Spacer()
                Button(allVisible ? "Deselect All" : "Select All") {
                    disableAutoSeedingFromSpend(spend: spend)
                    hideUncategorized = allVisible
                    for category in listed { category.isHidden = allVisible }
                }
                .font(.caption)
                .accessibilityIdentifier("catSelectAll")
            }
            ScrollView {
                VStack(spacing: 4) {
                    // Auto itself doesn't seed: turning it off reveals the dormant
                    // manual selections as-is.
                    Button { autoCategories.toggle() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.brand)
                                .frame(width: 22)
                            Text("Auto")
                                .foregroundStyle(Color.textPrimary)
                            Spacer(minLength: 16)
                            filterCheckbox(visible: autoCategories, hasSpend: false)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(autoCategories ? Color.brand.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Automatically show only categories with spending")
                    .accessibilityValue(autoCategories ? "on" : "off")
                    .accessibilityIdentifier("catAutoToggle")
                    Divider()
                    Button {
                        disableAutoSeedingFromSpend(spend: spend)
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
                            filterCheckbox(visible: uncatVisible, hasSpend: (spend[""] ?? 0) > 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(uncatVisible ? Color.brand.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catToggle-Uncategorized")
                    .accessibilityValue(uncatVisible ? "shown" : ((spend[""] ?? 0) > 0 ? "half" : "empty"))
                    ForEach(listed) { category in
                        let visible = autoCategories ? (spend[category.name] ?? 0) > 0
                                                     : !category.isHidden
                        Button {
                            disableAutoSeedingFromSpend(spend: spend)
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
                                filterCheckbox(visible: visible, hasSpend: (spend[category.name] ?? 0) > 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(visible ? Color.brand.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catToggle-\(category.name)")
                        .accessibilityValue(visible ? "shown" : ((spend[category.name] ?? 0) > 0 ? "half" : "empty"))
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
        let points = trend
        let count = max(points.count, 1)
        let idx = points.firstIndex { calendar.isDate($0.month, equalTo: point.month, toGranularity: .month) } ?? 0
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
