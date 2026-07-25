import Foundation

/// Read-only computed views over accounts and transactions. Pure functions so
/// the dashboard stays in sync with the store and the logic is unit-tested.
enum Analytics {
    struct CategoryTotal: Identifiable {
        var category: Category?
        var total: Decimal
        var id: String { category?.name ?? "_uncategorized" }
    }

    struct MonthPoint: Identifiable {
        var month: Date
        var income: Decimal
        var spending: Decimal
        var id: Date { month }
        var net: Decimal { income - spending }
    }

    /// Net worth = Assets + Debts. Debt balances are stored negative, so a plain
    /// sum of every account balance already nets the debts out.
    static func netWorth(_ accounts: [Account]) -> Decimal {
        accounts.reduce(Decimal(0)) { $0 + $1.balance }
    }

    static func inMonth(_ txns: [Transaction], of date: Date, calendar: Calendar) -> [Transaction] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return txns.filter { interval.contains($0.posted) }
    }

    /// Inflows in income categories for the month.
    static func monthlyIncome(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Decimal {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return 0 }
        return income(txns, in: interval)
    }

    /// Outflows (positive magnitude) excluding income and Transfers categories for the month.
    /// Transfers move money between a user's own accounts — not real spending.
    static func monthlySpending(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Decimal {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return 0 }
        return spending(txns, in: interval)
    }

    /// Inflows in income categories within `interval`.
    static func income(_ txns: [Transaction], in interval: DateInterval) -> Decimal {
        txns.filter { interval.contains($0.posted) && $0.category?.isIncome == true && $0.amount > 0 }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Outflows (positive magnitude) excluding income and Transfers within `interval`.
    static func spending(_ txns: [Transaction], in interval: DateInterval) -> Decimal {
        txns.filter { interval.contains($0.posted) && $0.amount < 0 && $0.category?.isIncome != true && $0.category?.name != "Transfers" }
            .reduce(Decimal(0)) { $0 - $1.amount }
    }

    /// Outflow total (positive magnitude) for one category in the month.
    static func spending(for category: Category, in txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Decimal {
        inMonth(txns, of: date, calendar: calendar)
            .filter { $0.amount < 0 && $0.category == category }
            .reduce(Decimal(0)) { $0 - $1.amount }
    }

    /// Spending grouped by category for the month, largest first.
    static func spendingByCategory(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> [CategoryTotal] {
        let outflows = inMonth(txns, of: date, calendar: calendar)
            .filter { $0.amount < 0 && $0.category?.isIncome != true }

        var totals: [String: (Category?, Decimal)] = [:]
        for txn in outflows {
            let key = txn.category?.name ?? "_uncategorized"
            let current = totals[key]?.1 ?? 0
            totals[key] = (txn.category, current - txn.amount)
        }
        return totals.values
            .map { CategoryTotal(category: $0.0, total: $0.1) }
            .sorted { $0.total > $1.total }
    }

    /// Spending categories for the month, including non-income categories with no
    /// spend (as $0 rows) so the Dashboard can list every category. Hidden
    /// categories and Transfers (internal movement, not spending) are excluded.
    /// Sorted by total descending, then name ascending so $0 rows land at the
    /// bottom in a stable order. The uncategorized row (if any) is preserved.
    static func spendingCategories(_ txns: [Transaction], categories: [Category],
                                   inMonthOf date: Date, calendar: Calendar = .current) -> [CategoryTotal] {
        spendingCategories(spent: spendingByCategory(txns, inMonthOf: date, calendar: calendar),
                           categories: categories)
    }

    /// Same, over an already-computed `spendingByCategory` result so callers that
    /// have it don't rescan the transaction list.
    static func spendingCategories(spent: [CategoryTotal], categories: [Category]) -> [CategoryTotal] {
        let spentNames = Set(spent.compactMap { $0.category?.name })
        let zeros = categories
            .filter { !$0.isIncome && $0.name != "Transfers" && !spentNames.contains($0.name) }
            .map { CategoryTotal(category: $0, total: 0) }
        return (spent + zeros)
            .filter { $0.category?.name != "Transfers" }
            .filter { !($0.category?.isHidden ?? false) }
            .sorted {
                $0.total != $1.total ? $0.total > $1.total
                                     : ($0.category?.name ?? "") < ($1.category?.name ?? "")
            }
    }

    /// Transactions in `date`'s month with no category — the triage-chip count.
    static func uncategorizedCount(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Int {
        inMonth(txns, of: date, calendar: calendar).filter { $0.category == nil }.count
    }

    /// What a flow metric measures for `monthOverMonthChange`.
    enum FlowMetric {
        case income, spending
    }

    /// Fractional month-over-month change of a month-to-date metric: this month
    /// through `date` vs last month through the same day (Jul 1–23 vs Jun 1–23,
    /// calendar-aware). nil when last month's span had none of the metric.
    static func monthOverMonthChange(_ metric: FlowMetric, txns: [Transaction],
                                     asOf date: Date, calendar: Calendar = .current) -> Double? {
        guard let thisMonth = calendar.dateInterval(of: .month, for: date),
              let lastCutoff = calendar.date(byAdding: .month, value: -1, to: date),
              let lastMonth = calendar.dateInterval(of: .month, for: lastCutoff),
              date > thisMonth.start
        else { return nil }
        let currentSpan = DateInterval(start: thisMonth.start, end: date)
        let previousSpan = DateInterval(start: lastMonth.start, end: lastCutoff)

        let value: (DateInterval) -> Decimal = { interval in
            switch metric {
            case .income: income(txns, in: interval)
            case .spending: spending(txns, in: interval)
            }
        }
        let previous = value(previousSpan)
        guard previous != 0 else { return nil }
        let current = value(currentSpan)
        return (((current - previous) / previous) as NSDecimalNumber).doubleValue
    }

    /// Safe-to-spend for `date`'s month: income so far, minus spending so far,
    /// minus confirmed recurring charges still due before month end. Bills are
    /// projected calendar-aware from their stored `nextDue`, so a weekly bill
    /// with several charges left this month counts each one.
    static func safeToSpend(_ txns: [Transaction], bills: [RecurringBill],
                            asOf date: Date, calendar: Calendar = .current) -> Decimal {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return 0 }
        let remaining = DateInterval(start: date, end: month.end)
        let upcoming = bills
            .filter { $0.confirmed && !$0.dismissed }
            .reduce(Decimal(0)) { sum, bill in
                guard let stored = bill.nextDue else { return sum }
                let anchor = RecurringSchedule.nextOccurrence(
                    onOrAfter: date, anchor: stored, cadence: bill.cadence, calendar: calendar)
                let due = RecurringSchedule.occurrences(
                    anchor: anchor, cadence: bill.cadence, in: remaining, calendar: calendar)
                return sum + bill.expectedAmount * Decimal(due.count)
            }
        return monthlyIncome(txns, inMonthOf: date, calendar: calendar)
            - monthlySpending(txns, inMonthOf: date, calendar: calendar)
            - upcoming
    }

    /// Visits/total/average for one merchant's charges in `date`'s year — the
    /// transaction-detail "This merchant" card. `txns` must already be filtered
    /// to the merchant (see `CategorizationEngine.normalizeMerchant`).
    static func merchantYearStats(_ txns: [Transaction], inYearOf date: Date, calendar: Calendar = .current)
        -> (visits: Int, total: Decimal, average: Decimal)? {
        guard let year = calendar.dateInterval(of: .year, for: date) else { return nil }
        let charges = txns.filter { year.contains($0.posted) && $0.amount < 0 }
        guard !charges.isEmpty else { return nil }
        let total = charges.reduce(Decimal(0)) { $0 - $1.amount }
        return (charges.count, total, total / Decimal(charges.count))
    }

    /// Per-account balance change across `interval`, from recorded snapshots —
    /// the net-worth detail's "Change this range" card. Baseline is the last
    /// snapshot on/before the range start (or the earliest inside it, mirroring
    /// `recentChange`'s young-history fallback); accounts with fewer than two
    /// usable snapshots are omitted. `snapshots` must be day-ascending.
    /// Sorted by delta, biggest gain first.
    static func accountRangeDeltas(_ snapshots: [AccountBalanceSnapshot], accounts: [Account],
                                   in interval: DateInterval) -> [(account: Account, delta: Decimal)] {
        let byAccount = Dictionary(grouping: snapshots, by: \.accountId)
        return accounts.compactMap { account -> (Account, Decimal)? in
            guard let rows = byAccount[account.id] else { return nil }
            let inRange = rows.filter { $0.day <= interval.end }
            guard let latest = inRange.last else { return nil }
            let baseline = inRange.last(where: { $0.day <= interval.start })
                ?? inRange.first(where: { $0.day >= interval.start })
            guard let baseline, baseline.day < latest.day else { return nil }
            return (account, latest.balance - baseline.balance)
        }
        .sorted { $0.1 > $1.1 }
    }

    /// Net-worth change over the trailing `window` days: latest snapshot vs. the most
    /// recent snapshot on or before `window` days ago. Before that much history exists,
    /// falls back to the earliest snapshot so the change still shows. Returns the
    /// fractional change and the span in days (capped at `window`). nil with <2
    /// snapshots, a flat span, or a zero baseline. `snapshots` must be day-ascending.
    static func recentChange(_ snapshots: [NetWorthSnapshot], asOf date: Date,
                             window: Int = 30, calendar: Calendar = .current)
        -> (percent: Double, days: Int)? {
        guard snapshots.count >= 2, let last = snapshots.last else { return nil }
        let cutoff = calendar.date(byAdding: .day, value: -window, to: date) ?? date
        let baseline = snapshots.last(where: { $0.day <= cutoff }) ?? snapshots.first!
        guard baseline.day < last.day else { return nil }
        let from = (baseline.value as NSDecimalNumber).doubleValue
        let to = (last.value as NSDecimalNumber).doubleValue
        guard from != 0 else { return nil }
        let span = calendar.dateComponents([.day], from: baseline.day, to: last.day).day ?? 0
        return ((to - from) / abs(from), min(window, span))
    }

    /// Income/spending per month for the trailing `count` months ending in `date`'s month.
    /// One pass over `txns`, bucketing by month start — not a filter per month.
    static func monthlyTrend(_ txns: [Transaction], endingIn date: Date, count: Int, calendar: Calendar = .current) -> [MonthPoint] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        let months: [Date] = (0..<count).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: thisMonth)
        }
        guard let earliest = months.first,
              let end = calendar.dateInterval(of: .month, for: date)?.end else { return [] }

        // Same per-transaction tests as monthlyIncome/monthlySpending.
        var buckets: [Date: (income: Decimal, spending: Decimal)] = [:]
        for txn in txns where txn.posted >= earliest && txn.posted < end {
            guard let month = calendar.dateInterval(of: .month, for: txn.posted)?.start else { continue }
            if txn.category?.isIncome == true, txn.amount > 0 {
                buckets[month, default: (0, 0)].income += txn.amount
            } else if txn.amount < 0, txn.category?.isIncome != true, txn.category?.name != "Transfers" {
                buckets[month, default: (0, 0)].spending -= txn.amount
            }
        }
        return months.map { month in
            let b = buckets[month] ?? (0, 0)
            return MonthPoint(month: month, income: b.income, spending: b.spending)
        }
    }
}
