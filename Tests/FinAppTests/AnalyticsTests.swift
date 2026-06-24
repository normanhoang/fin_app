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

    func testNetWorthSumsBalancesIncludingNegative() {
        _ = account("1000.00"); _ = account("-250.50"); _ = account("23935.35")
        let accounts = try! ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(Analytics.netWorth(accounts), Decimal(string: "24684.85"))
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
}
