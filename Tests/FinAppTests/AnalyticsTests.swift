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
}
