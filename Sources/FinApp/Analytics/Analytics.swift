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

    /// Outflows (positive magnitude) excluding income categories for the month.
    static func monthlySpending(_ txns: [Transaction], inMonthOf date: Date, calendar: Calendar = .current) -> Decimal {
        inMonth(txns, of: date, calendar: calendar)
            .filter { $0.amount < 0 && $0.category?.isIncome != true }
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

    /// Income/spending per month for the trailing `count` months ending in `date`'s month.
    static func monthlyTrend(_ txns: [Transaction], endingIn date: Date, count: Int, calendar: Calendar = .current) -> [MonthPoint] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        return (0..<count).reversed().compactMap { offset -> MonthPoint? in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { return nil }
            return MonthPoint(
                month: month,
                income: monthlyIncome(txns, inMonthOf: month, calendar: calendar),
                spending: monthlySpending(txns, inMonthOf: month, calendar: calendar)
            )
        }
    }
}
