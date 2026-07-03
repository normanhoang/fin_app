import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class TransactionFilterStateTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func account(_ id: String = UUID().uuidString) -> Account {
        let a = Account(id: id, org: "B", name: "A", currency: "USD",
                        balance: 0, balanceDate: Date())
        ctx.insert(a)
        return a
    }

    private func cat(_ name: String, income: Bool = false) -> FinApp.Category {
        let c = FinApp.Category(name: name, colorHex: "#000", systemIcon: "tag", isIncome: income)
        ctx.insert(c)
        return c
    }

    private func txn(_ amount: String, _ d: Date = .now,
                     account: Account? = nil, category: FinApp.Category? = nil) -> Transaction {
        let t = Transaction(id: UUID().uuidString, posted: d, amount: Decimal(string: amount)!,
                            detail: "x", account: account, category: category)
        ctx.insert(t)
        return t
    }

    private func monthInterval(of filter: TransactionFilterState) -> DateInterval? {
        filter.month.flatMap { cal.dateInterval(of: .month, for: $0) }
    }

    // MARK: Default state

    func testDefaultStateIsInactiveAndMatchesEverything() {
        let filter = TransactionFilterState()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(txn("-5.00"), monthInterval: nil))
        XCTAssertTrue(filter.matches(txn("5.00", category: cat("Salary", income: true)), monthInterval: nil))
    }

    // MARK: Deep-link mapping

    func testDeepLinkMapping() {
        XCTAssertEqual(TransactionFilterState(.all), TransactionFilterState())
        XCTAssertEqual(TransactionFilterState(.income).type, .income)
        XCTAssertEqual(TransactionFilterState(.spending).type, .spending)
        XCTAssertEqual(TransactionFilterState(.uncategorized).categories, [.uncategorized])
        XCTAssertEqual(TransactionFilterState(.category("Housing")).categories, [.named("Housing")])
        XCTAssertTrue(TransactionFilterState(.income).isActive)
        XCTAssertFalse(TransactionFilterState(.all).isActive)
    }

    // MARK: Month

    func testMonthFilterBoundaries() {
        var filter = TransactionFilterState()
        filter.month = date(2026, 6, 1, 0)
        let interval = monthInterval(of: filter)

        XCTAssertTrue(filter.matches(txn("-1.00", date(2026, 6, 1, 0)), monthInterval: interval))
        XCTAssertTrue(filter.matches(txn("-1.00", date(2026, 6, 30, 23)), monthInterval: interval))
        XCTAssertFalse(filter.matches(txn("-1.00", date(2026, 5, 31, 23)), monthInterval: interval))
        XCTAssertFalse(filter.matches(txn("-1.00", date(2026, 7, 1, 0)), monthInterval: interval))
    }

    // MARK: Categories

    func testMultiCategoryIncludingUncategorized() {
        var filter = TransactionFilterState()
        filter.categories = [.named("Housing"), .uncategorized]

        XCTAssertTrue(filter.matches(txn("-1.00", category: cat("Housing")), monthInterval: nil))
        XCTAssertTrue(filter.matches(txn("-1.00"), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-1.00", category: cat("Dining")), monthInterval: nil))
    }

    // MARK: Accounts

    func testAccountFilter() {
        var filter = TransactionFilterState()
        let checking = account("acc-1")
        filter.accountIDs = ["acc-1"]

        XCTAssertTrue(filter.matches(txn("-1.00", account: checking), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-1.00", account: account("acc-2")), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-1.00"), monthInterval: nil), "nil account fails a non-empty account filter")
    }

    // MARK: Type

    func testIncomeRequiresIncomeCategoryAndPositiveAmount() {
        var filter = TransactionFilterState()
        filter.type = .income
        let salary = cat("Salary", income: true)

        XCTAssertTrue(filter.matches(txn("100.00", category: salary), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-100.00", category: salary), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("100.00", category: cat("Dining")), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("100.00"), monthInterval: nil))
    }

    func testSpendingExcludesIncomeAndTransfers() {
        var filter = TransactionFilterState()
        filter.type = .spending

        XCTAssertTrue(filter.matches(txn("-50.00", category: cat("Dining")), monthInterval: nil))
        XCTAssertTrue(filter.matches(txn("-50.00"), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("50.00", category: cat("Refunds")), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-50.00", category: cat("Salary", income: true)), monthInterval: nil))
        XCTAssertFalse(filter.matches(txn("-50.00", category: cat("Transfers")), monthInterval: nil))
    }

    // MARK: Combined

    func testFacetsCombineWithAND() {
        var filter = TransactionFilterState()
        let dining = cat("Dining")
        let checking = account("acc-1")
        filter.month = date(2026, 6, 1, 0)
        filter.categories = [.named("Dining")]
        filter.accountIDs = ["acc-1"]
        filter.type = .spending
        let interval = monthInterval(of: filter)

        XCTAssertTrue(filter.matches(
            txn("-20.00", date(2026, 6, 15), account: checking, category: dining), monthInterval: interval))
        // Each facet failing alone breaks the match.
        XCTAssertFalse(filter.matches(
            txn("-20.00", date(2026, 7, 15), account: checking, category: dining), monthInterval: interval))
        XCTAssertFalse(filter.matches(
            txn("-20.00", date(2026, 6, 15), account: checking, category: cat("Housing")), monthInterval: interval))
        XCTAssertFalse(filter.matches(
            txn("-20.00", date(2026, 6, 15), account: account("acc-2"), category: dining), monthInterval: interval))
        XCTAssertFalse(filter.matches(
            txn("20.00", date(2026, 6, 15), account: checking, category: dining), monthInterval: interval))
    }
}
