import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class AnalyticsTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func account(_ balance: String) -> Account {
        let a = Account(id: UUID().uuidString, org: "B", name: "A", currency: "USD",
                        balance: Decimal(string: balance)!, balanceDate: Date())
        ctx.insert(a)
        return a
    }

    @discardableResult
    private func txn(_ amount: String, _ d: Date, category: FinApp.Category? = nil) -> Transaction {
        let t = Transaction(id: UUID().uuidString, posted: d, amount: Decimal(string: amount)!, detail: "x", category: category)
        ctx.insert(t)
        return t
    }

    private func cat(_ name: String, income: Bool = false) -> FinApp.Category {
        let c = FinApp.Category(name: name, colorHex: "#000", systemIcon: "tag", isIncome: income)
        ctx.insert(c)
        return c
    }

    @discardableResult
    private func snap(_ value: String, daysAgo: Int, from ref: Date) -> NetWorthSnapshot {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: ref)!
        let s = NetWorthSnapshot(day: cal.startOfDay(for: d), value: Decimal(string: value)!)
        ctx.insert(s)
        return s
    }

    private func snapshots() -> [NetWorthSnapshot] {
        (try! ctx.fetch(FetchDescriptor<NetWorthSnapshot>())).sorted { $0.day < $1.day }
    }

    func testRecentChangeUsesFullHistoryWhenYoungerThan30Days() {
        let now = date(2026, 6, 30)
        snap("100.00", daysAgo: 5, from: now)
        snap("110.00", daysAgo: 0, from: now)
        let result = Analytics.recentChange(snapshots(), asOf: now, calendar: cal)
        XCTAssertEqual(result?.days, 5)
        XCTAssertEqual(result!.percent, 0.10, accuracy: 0.0001)
    }

    func testRecentChangeCapsSpanAt30DaysWithLongHistory() {
        let now = date(2026, 6, 30)
        for d in stride(from: 40, through: 0, by: -1) {
            snap(String(1000 + (40 - d)), daysAgo: d, from: now) // rising ~1 per day
        }
        let result = Analytics.recentChange(snapshots(), asOf: now, calendar: cal)
        XCTAssertEqual(result?.days, 30, "span should cap at the 30-day window")
    }

    func testRecentChangeNilWithSingleSnapshot() {
        let now = date(2026, 6, 30)
        snap("100.00", daysAgo: 0, from: now)
        XCTAssertNil(Analytics.recentChange(snapshots(), asOf: now, calendar: cal))
    }

    func testNetWorthSumsBalancesIncludingNegative() {
        _ = account("1000.00"); _ = account("-250.50"); _ = account("23935.35")
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(Analytics.netWorth(accounts), Decimal(string: "24684.85"))
    }

    func testNetWorthAddsDebtsStoredNegative() {
        let cash = account("5000.00")
        cash.accountType = .cash
        let card = account("-600.00")   // credit card stored negative
        card.accountType = .creditCard
        let loan = account("-1500.00")  // loan stored negative
        loan.accountType = .loan
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())
        // Assets + Debts: 5000 + (−600) + (−1500)
        XCTAssertEqual(Analytics.netWorth(accounts), Decimal(string: "2900.00"))
    }

    func testSpendingByCategoryIgnoresHiddenAndIncludesTransfers() {
        // The Dashboard's Auto category mode relies on both properties.
        let hidden = cat("Food")
        hidden.isHidden = true
        let transfers = cat("Transfers")
        txn("-40.00", date(2026, 6, 5), category: hidden)
        txn("-25.00", date(2026, 6, 6), category: transfers)
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let names = Analytics.spendingByCategory(txns, inMonthOf: date(2026, 6, 1), calendar: cal)
            .map { $0.category?.name }
        XCTAssertTrue(names.contains("Food"), "isHidden must be ignored (Dashboard Auto relies on this)")
        XCTAssertTrue(names.contains("Transfers"), "Transfers included — callers must filter them out")
    }

    func testMonthlyIncomeSumsIncomeCategoryInMonth() {
        let income = cat("Income", income: true)
        txn("2000.00", date(2026, 6, 5), category: income)
        txn("500.00", date(2026, 6, 20), category: income)
        txn("999.00", date(2026, 5, 5), category: income) // other month
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Analytics.monthlyIncome(txns, inMonthOf: date(2026, 6, 1), calendar: cal), Decimal(string: "2500.00"))
    }

    func testMonthlySpendingSumsOutflowsExcludingIncome() {
        let food = cat("Food")
        let income = cat("Income", income: true)
        txn("-40.00", date(2026, 6, 5), category: food)
        txn("-60.00", date(2026, 6, 6), category: food)
        txn("2000.00", date(2026, 6, 7), category: income) // inflow, ignored
        txn("-10.00", date(2026, 5, 1), category: food)     // other month
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Analytics.monthlySpending(txns, inMonthOf: date(2026, 6, 1), calendar: cal), Decimal(string: "100.00"))
    }

    func testSpendingForSpecificCategory() {
        let food = cat("Food"); let shop = cat("Shopping")
        txn("-40.00", date(2026, 6, 5), category: food)
        txn("-10.00", date(2026, 6, 7), category: food)
        txn("-100.00", date(2026, 6, 6), category: shop)
        txn("-99.00", date(2026, 5, 6), category: food) // other month
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Analytics.spending(for: food, in: txns, inMonthOf: date(2026, 6, 1), calendar: cal), Decimal(string: "50.00"))
    }

    func testSpendingByCategorySortedDescending() {
        let food = cat("Food"); let shop = cat("Shopping")
        txn("-40.00", date(2026, 6, 5), category: food)
        txn("-100.00", date(2026, 6, 6), category: shop)
        txn("-10.00", date(2026, 6, 7), category: food)
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let result = Analytics.spendingByCategory(txns, inMonthOf: date(2026, 6, 1), calendar: cal)
        XCTAssertEqual(result.map(\.category?.name), ["Shopping", "Food"])
        XCTAssertEqual(result.map(\.total), [Decimal(string: "100.00"), Decimal(string: "50.00")])
    }

    func testSpendingCategoriesIncludesZeroTotalCategories() {
        let food = cat("Food")            // has spend
        _ = cat("Shopping")               // no spend → $0 row
        _ = cat("Transport")              // no spend → $0 row
        _ = cat("Paycheck", income: true) // income → excluded
        let hidden = cat("Bills"); hidden.isHidden = true // hidden → excluded
        _ = cat("Transfers")              // internal movement → excluded
        txn("-40.00", date(2026, 6, 5), category: food)
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let cats = try! ctx.fetch(FetchDescriptor<FinApp.Category>())

        let result = Analytics.spendingCategories(txns, categories: cats,
                                                  inMonthOf: date(2026, 6, 1), calendar: cal)
        // Food (40) first; the two $0 categories follow, alphabetically. Income,
        // hidden, and Transfers are excluded.
        XCTAssertEqual(result.map(\.category?.name), ["Food", "Shopping", "Transport"])
        XCTAssertEqual(result.map(\.total),
                       [Decimal(string: "40.00"), Decimal(0), Decimal(0)])
    }

    // MARK: - Uncategorized count

    func testUncategorizedCountCurrentMonthOnly() {
        let food = cat("Food")
        txn("-10.00", date(2026, 7, 3))                  // counts
        txn("25.00", date(2026, 7, 10))                  // counts (sign irrelevant)
        txn("-5.00", date(2026, 7, 5), category: food)   // categorized
        txn("-7.00", date(2026, 6, 20))                  // other month
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Analytics.uncategorizedCount(txns, inMonthOf: date(2026, 7, 15), calendar: cal), 2)
    }

    // MARK: - Month-over-month change

    func testMonthOverMonthSpendingDown() {
        txn("-100.00", date(2026, 6, 5))
        txn("-50.00", date(2026, 6, 25)) // after the compared span (Jun 1–20)
        txn("-80.00", date(2026, 7, 10))
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let change = Analytics.monthOverMonthChange(.spending, txns: txns,
                                                    asOf: date(2026, 7, 20), calendar: cal)
        XCTAssertEqual(change!, -0.20, accuracy: 0.0001)
    }

    func testMonthOverMonthIncomeUp() {
        let payroll = cat("Paycheck", income: true)
        txn("1000.00", date(2026, 6, 10), category: payroll)
        txn("1100.00", date(2026, 7, 10), category: payroll)
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let change = Analytics.monthOverMonthChange(.income, txns: txns,
                                                    asOf: date(2026, 7, 20), calendar: cal)
        XCTAssertEqual(change!, 0.10, accuracy: 0.0001)
    }

    func testMonthOverMonthNilOnZeroBaseline() {
        txn("-80.00", date(2026, 7, 10))
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertNil(Analytics.monthOverMonthChange(.spending, txns: txns,
                                                    asOf: date(2026, 7, 20), calendar: cal))
    }

    // MARK: - Safe to spend

    private func bill(_ merchant: String, _ amount: String, due: Date,
                      cadence: Cadence = .monthly, confirmed: Bool = true,
                      dismissed: Bool = false) -> RecurringBill {
        let b = RecurringBill(merchantName: merchant, expectedAmount: Decimal(string: amount)!,
                              cadence: cadence, lastSeen: due, nextDue: due,
                              confirmed: confirmed, dismissed: dismissed)
        ctx.insert(b)
        return b
    }

    func testSafeToSpendSubtractsUpcomingConfirmedBills() {
        let payroll = cat("Paycheck", income: true)
        txn("3000.00", date(2026, 7, 5), category: payroll)
        txn("-1000.00", date(2026, 7, 8))
        _ = bill("netflix", "15.49", due: date(2026, 7, 25))                    // counts
        _ = bill("gym", "25.00", due: date(2026, 8, 3))                         // next month
        _ = bill("spotify", "12.00", due: date(2026, 7, 28), confirmed: false)  // candidate
        _ = bill("hulu", "8.00", due: date(2026, 7, 26), dismissed: true)       // dismissed
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let bills = try! ctx.fetch(FetchDescriptor<RecurringBill>())
        // 3000 − 1000 − 15.49
        XCTAssertEqual(Analytics.safeToSpend(txns, bills: bills,
                                             asOf: date(2026, 7, 20), calendar: cal),
                       Decimal(string: "1984.51"))
    }

    func testSafeToSpendCountsEachRemainingWeeklyCharge() {
        _ = bill("gym", "10.00", due: date(2026, 7, 22), cadence: .weekly)
        let bills = try! ctx.fetch(FetchDescriptor<RecurringBill>())
        // Jul 22 and Jul 29 remain before Aug — two charges, no income/spending.
        XCTAssertEqual(Analytics.safeToSpend([], bills: bills,
                                             asOf: date(2026, 7, 20), calendar: cal),
                       Decimal(string: "-20.00"))
    }

    // MARK: - Merchant year stats

    func testMerchantYearStatsCountsChargesThisYear() {
        txn("-6.45", date(2026, 2, 3))
        txn("-7.15", date(2026, 5, 9))
        txn("-13.50", date(2026, 7, 1))
        txn("-9.99", date(2025, 12, 20))  // last year — excluded
        txn("25.00", date(2026, 6, 1))    // inflow — excluded
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        let stats = Analytics.merchantYearStats(txns, inYearOf: date(2026, 7, 20), calendar: cal)
        XCTAssertEqual(stats?.visits, 3)
        XCTAssertEqual(stats?.total, Decimal(string: "27.10"))
        XCTAssertEqual(stats.map { ($0.average as NSDecimalNumber).doubleValue }!, 9.0333, accuracy: 0.001)
    }

    func testMerchantYearStatsNilWithNoCharges() {
        txn("25.00", date(2026, 6, 1))
        let txns = try! ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertNil(Analytics.merchantYearStats(txns, inYearOf: date(2026, 7, 20), calendar: cal))
    }

    // MARK: - Account range deltas

    private func accountSnap(_ id: String, _ value: String, day: Date) {
        ctx.insert(AccountBalanceSnapshot(accountId: id, day: cal.startOfDay(for: day),
                                          balance: Decimal(string: value)!))
    }

    func testAccountRangeDeltasBaselineOnOrBeforeStart() {
        let a = account("1100.00"); a.id = "a"
        let b = account("500.00"); b.id = "b"
        accountSnap("a", "1000.00", day: date(2026, 6, 15))
        accountSnap("a", "1100.00", day: date(2026, 7, 20))
        accountSnap("b", "550.00", day: date(2026, 7, 5))   // inside range only
        accountSnap("b", "500.00", day: date(2026, 7, 20))
        let interval = DateInterval(start: date(2026, 6, 20), end: date(2026, 7, 20))
        let snaps = (try! ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())).sorted { $0.day < $1.day }
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())
        let deltas = Analytics.accountRangeDeltas(snaps, accounts: accounts, in: interval)
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(deltas[0].account.id, "a", "Sorted biggest gain first")
        XCTAssertEqual(deltas[0].delta, Decimal(string: "100.00"))
        XCTAssertEqual(deltas[1].delta, Decimal(string: "-50.00"), "Falls back to earliest in-range snapshot")
    }

    func testAccountRangeDeltasOmitsSingleSnapshotAccounts() {
        let a = account("100.00"); a.id = "solo"
        accountSnap("solo", "100.00", day: date(2026, 7, 10))
        let interval = DateInterval(start: date(2026, 7, 1), end: date(2026, 7, 20))
        let snaps = try! ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())
        XCTAssertTrue(Analytics.accountRangeDeltas(snaps, accounts: accounts, in: interval).isEmpty)
    }

    func testAccountRangeDeltasVaryByInterval() {
        let a = account("1300.00"); a.id = "a"
        accountSnap("a", "1000.00", day: date(2026, 5, 1))
        accountSnap("a", "1200.00", day: date(2026, 6, 15))
        accountSnap("a", "1300.00", day: date(2026, 7, 20))
        let snaps = (try! ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())).sorted { $0.day < $1.day }
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())

        let wide = Analytics.accountRangeDeltas(
            snaps, accounts: accounts,
            in: DateInterval(start: date(2026, 6, 1), end: date(2026, 7, 20)))
        let narrow = Analytics.accountRangeDeltas(
            snaps, accounts: accounts,
            in: DateInterval(start: date(2026, 7, 1), end: date(2026, 7, 20)))

        XCTAssertEqual(wide.first?.delta, Decimal(string: "300.00"), "Baseline is the May 1 snapshot")
        XCTAssertEqual(narrow.first?.delta, Decimal(string: "100.00"), "Baseline is the Jun 15 snapshot")
        XCTAssertNotEqual(wide.first?.delta, narrow.first?.delta,
                          "Switching the range must move the numbers")
    }

    /// A window reaching further back than the stored history falls back to the
    /// earliest snapshot rather than returning nil, so every over-long window
    /// reports the same full-history delta. Intentional — don't "fix" it.
    func testAccountRangeDeltasCollapseWhenWindowExceedsHistory() {
        let a = account("1300.00"); a.id = "a"
        accountSnap("a", "1000.00", day: date(2026, 6, 15))
        accountSnap("a", "1300.00", day: date(2026, 7, 20))
        let snaps = (try! ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())).sorted { $0.day < $1.day }
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())

        let oneYear = Analytics.accountRangeDeltas(
            snaps, accounts: accounts,
            in: DateInterval(start: date(2025, 7, 20), end: date(2026, 7, 20)))
        let all = Analytics.accountRangeDeltas(
            snaps, accounts: accounts,
            in: DateInterval(start: date(2020, 1, 1), end: date(2026, 7, 20)))

        XCTAssertEqual(oneYear.first?.delta, Decimal(string: "300.00"), "Full history, not nil")
        XCTAssertEqual(all.first?.delta, oneYear.first?.delta,
                       "Windows longer than the history collapse to the same delta")
    }

    func testSafeToSpendRollsOverdueAnchorForward() {
        // Stored nextDue is stale (Jul 1); rolled forward from Jul 20 the next
        // monthly charge lands Aug 1 — outside the month, so nothing subtracts.
        _ = bill("netflix", "15.49", due: date(2026, 7, 1))
        let bills = try! ctx.fetch(FetchDescriptor<RecurringBill>())
        XCTAssertEqual(Analytics.safeToSpend([], bills: bills,
                                             asOf: date(2026, 7, 20), calendar: cal), 0)
    }
}
