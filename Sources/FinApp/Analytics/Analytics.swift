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
        inMonth(txns, of: date, calendar: calendar)
            .filter { $0.category?.isIncome == true && $0.amount > 0 }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Outflows (positive magnitude) excluding income and Transfers categories for the month.
    /// Transfers move money between a user's own accounts — not real spending.
    static func monthlySpending(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Decimal {
        inMonth(txns, of: date, calendar: calendar)
            .filter { $0.amount < 0 && $0.category?.isIncome != true && $0.category?.name != "Transfers" }
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
        let spent = spendingByCategory(txns, inMonthOf: date, calendar: calendar)
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
