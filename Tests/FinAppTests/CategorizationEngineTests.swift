import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class CategorizationEngineTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    private func category(_ name: String) -> FinApp.Category {
        let c = FinApp.Category(name: name, colorHex: "#000000", systemIcon: "tag")
        ctx.insert(c)
        return c
    }

    private func rule(_ keyword: String, _ cat: FinApp.Category, priority: Int = 100) -> CategoryRule {
        let r = CategoryRule(keyword: keyword, priority: priority, category: cat)
        ctx.insert(r)
        return r
    }

    func testLearnThenCategorizeAllPropagatesToSimilarTransactions() {
        let dining = category("Dining")
        let t1 = Transaction(id: "1", posted: Date(), amount: -5, detail: "STARBUCKS #123", payee: "STARBUCKS #123")
        let t2 = Transaction(id: "2", posted: Date(), amount: -6, detail: "STARBUCKS #999", payee: "STARBUCKS #999")
        ctx.insert(t1); ctx.insert(t2)

        // User categorizes one Starbucks; the rule should catch the other.
        CategorizationEngine.learn(from: t1, category: dining, in: ctx)
        CategorizationEngine.categorizeAll(in: ctx)

        XCTAssertEqual(t1.category, dining)
        XCTAssertEqual(t2.category, dining, "Similar merchant should be auto-categorized")
        XCTAssertTrue(t1.categorizedByUser)
        XCTAssertFalse(t2.categorizedByUser, "Propagated category is a rule match, not a manual set")
    }

    func testAssignPropagatesToSameMerchantOnly() {
        let dining = category("Dining")
        let t1 = Transaction(id: "1", posted: Date(), amount: -5, detail: "STARBUCKS #123", payee: "STARBUCKS #123")
        let t2 = Transaction(id: "2", posted: Date(), amount: -6, detail: "STARBUCKS #999", payee: "STARBUCKS #999")
        let other = Transaction(id: "3", posted: Date(), amount: -7, detail: "SHELL GAS", payee: "SHELL GAS")
        let userSet = Transaction(id: "4", posted: Date(), amount: -8, detail: "STARBUCKS #555",
                                  payee: "STARBUCKS #555", categorizedByUser: true)
        [t1, t2, other, userSet].forEach { ctx.insert($0) }

        CategorizationEngine.assign(dining, to: t1, in: ctx)

        XCTAssertEqual(t1.category, dining)
        XCTAssertEqual(t2.category, dining, "Scoped apply must reach the merchant's other charges")
        XCTAssertNil(other.category, "Unrelated merchants stay untouched")
        XCTAssertNil(userSet.category, "User-set transactions are never overwritten")
    }

    func testMatchingRuleAssignsCategory() {
        let food = category("Food")
        let rules = [rule("coffee", food)]
        XCTAssertEqual(CategorizationEngine.bestCategory(forMatchText: "blue bottle coffee", rules: rules), food)
    }

    func testNoMatchReturnsNil() {
        let rules = [rule("coffee", category("Food"))]
        XCTAssertNil(CategorizationEngine.bestCategory(forMatchText: "shell gas station", rules: rules))
    }

    func testLowerPriorityValueWins() {
        let food = category("Food")
        let coffeeShops = category("Coffee")
        let rules = [
            rule("coffee", food, priority: 100),
            rule("coffee", coffeeShops, priority: 0),
        ]
        XCTAssertEqual(CategorizationEngine.bestCategory(forMatchText: "coffee", rules: rules), coffeeShops)
    }

    func testCategorizeSkipsUserCategorized() {
        let food = category("Food")
        let txn = Transaction(id: "t1", posted: Date(), amount: -5, detail: "COFFEE", categorizedByUser: true)
        ctx.insert(txn)
        CategorizationEngine.categorize(txn, using: [rule("coffee", food)])
        XCTAssertNil(txn.category) // untouched because user set it
    }

    func testCategorizeAssignsWhenNotUserCategorized() {
        let food = category("Food")
        let txn = Transaction(id: "t1", posted: Date(), amount: -5, detail: "COFFEE SHOP", payee: "Coffee Shop")
        ctx.insert(txn)
        CategorizationEngine.categorize(txn, using: [rule("coffee", food)])
        XCTAssertEqual(txn.category, food)
    }

    func testLearnCreatesUserRuleAndMarksTransaction() {
        let food = category("Food")
        let txn = Transaction(id: "t1", posted: Date(), amount: -5, detail: "COFFEE SHOP #42", payee: "Coffee Shop")
        ctx.insert(txn)

        let learned = CategorizationEngine.learn(from: txn, category: food, in: ctx)

        XCTAssertEqual(txn.category, food)
        XCTAssertTrue(txn.categorizedByUser)
        XCTAssertTrue(learned.createdByUser)
        XCTAssertEqual(learned.category, food)
        // The learned rule should catch the same merchant again.
        XCTAssertTrue(learned.matches("coffee shop #99".lowercased()))
    }

    func testNormalizeMerchantStripsNumericTokens() {
        XCTAssertEqual(CategorizationEngine.normalizeMerchant("COFFEE SHOP #42"), "coffee shop")
        XCTAssertEqual(CategorizationEngine.normalizeMerchant("AMEX EPAYMENT 12345 ACH"), "amex epayment ach")
    }
}
