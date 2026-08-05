import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class CategorySeedTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    func testSeedInsertsCategoriesAndRules() {
        CategorySeed.seedIfNeeded(in: ctx)
        XCTAssertGreaterThan((try? ctx.fetch(FetchDescriptor<FinApp.Category>()))?.count ?? 0, 5)
        XCTAssertGreaterThan((try? ctx.fetch(FetchDescriptor<CategoryRule>()))?.count ?? 0, 5)
    }

    func testSeedIsIdempotent() {
        CategorySeed.seedIfNeeded(in: ctx)
        let count = (try? ctx.fetch(FetchDescriptor<FinApp.Category>()))?.count ?? 0
        CategorySeed.seedIfNeeded(in: ctx)
        XCTAssertEqual((try? ctx.fetch(FetchDescriptor<FinApp.Category>()))?.count ?? 0, count)
    }

    func testEnsureMissingAddsNewSeedWithoutDuplicating() {
        // Simulate an older install missing the Bars category.
        let stale = Category(name: "Income", colorHex: "#000", systemIcon: "x", isIncome: true)
        ctx.insert(stale)

        CategorySeed.ensureMissing(in: ctx)
        let names = (try? ctx.fetch(FetchDescriptor<FinApp.Category>()))?.map(\.name) ?? []
        XCTAssertTrue(names.contains("Bars"))
        XCTAssertEqual(names.filter { $0 == "Income" }.count, 1)

        // Second pass adds nothing.
        let count = names.count
        CategorySeed.ensureMissing(in: ctx)
        XCTAssertEqual((try? ctx.fetch(FetchDescriptor<FinApp.Category>()))?.count ?? 0, count)
    }

    func testEnsureExclusionsInsertsRuleOnce() {
        CategorySeed.ensureExclusions(in: ctx)
        let exclusions = ((try? ctx.fetch(FetchDescriptor<CategoryRule>())) ?? [])
            .filter { $0.category == nil }
        XCTAssertEqual(exclusions.map(\.keyword), ["transfer to venmo"])

        CategorySeed.ensureExclusions(in: ctx)
        let after = ((try? ctx.fetch(FetchDescriptor<CategoryRule>())) ?? [])
            .filter { $0.category == nil }
        XCTAssertEqual(after.count, 1, "Second pass must not duplicate the exclusion rule")
    }

    func testEnsureExclusionsKeepsExistingCategorizedMatches() {
        CategorySeed.seedIfNeeded(in: ctx)
        let transfers = ((try? ctx.fetch(FetchDescriptor<FinApp.Category>())) ?? [])
            .first { $0.name == "Transfers" }
        let categorized = Transaction(id: "1", posted: Date(), amount: -20,
                                      detail: "Transfer to Venmo", payee: "Transfer to Venmo",
                                      category: transfers)
        let uncategorized = Transaction(id: "2", posted: Date(), amount: -35,
                                        detail: "Transfer to Venmo", payee: "Transfer to Venmo")
        let unrelated = Transaction(id: "3", posted: Date(), amount: -7,
                                    detail: "SHELL GAS", payee: "SHELL GAS")
        [categorized, uncategorized, unrelated].forEach { ctx.insert($0) }

        CategorySeed.ensureExclusions(in: ctx)
        CategorizationEngine.categorizeAll(in: ctx)

        XCTAssertEqual(categorized.category, transfers, "Existing categorized match keeps its category through re-sync")
        XCTAssertFalse(categorized.categorizedByUser, "Preserved history must not masquerade as a manual choice")
        XCTAssertFalse(uncategorized.categorizedByUser)
        XCTAssertNil(uncategorized.category, "Uncategorized match stays uncategorized under the exclusion")
        XCTAssertFalse(unrelated.categorizedByUser)
    }

    func testSeededStoreLeavesVenmoTransferUncategorized() {
        CategorySeed.seedIfNeeded(in: ctx)
        CategorySeed.ensureExclusions(in: ctx)
        let venmoOut = Transaction(id: "1", posted: Date(), amount: -50,
                                   detail: "Transfer to Venmo", payee: "Transfer to Venmo")
        let cashout = Transaction(id: "2", posted: Date(), amount: 120,
                                  detail: "Venmo Cashout", payee: "Venmo Cashout")
        ctx.insert(venmoOut); ctx.insert(cashout)

        CategorizationEngine.categorizeAll(in: ctx)

        XCTAssertNil(venmoOut.category)
        XCTAssertEqual(cashout.category?.name, "Transfers", "Other Venmo activity still categorizes normally")
    }

    func testEnsureExclusionsIsCaseInsensitive() {
        CategorySeed.seedIfNeeded(in: ctx)
        let txn = Transaction(id: "1", posted: Date(), amount: -20,
                              detail: "Transfer to PayPal", payee: "Transfer to PayPal")
        ctx.insert(txn)

        CategorySeed.ensureExclusions(in: ctx, keywords: ["Transfer to PayPal"])
        CategorySeed.ensureExclusions(in: ctx, keywords: ["Transfer to PayPal"])
        CategorizationEngine.categorizeAll(in: ctx)

        let exclusions = ((try? ctx.fetch(FetchDescriptor<CategoryRule>())) ?? [])
            .filter { $0.category == nil }
        XCTAssertEqual(exclusions.map(\.keyword), ["transfer to paypal"],
                       "Mixed-case keyword must be stored lowercased and never duplicated")
        XCTAssertNil(txn.category,
                     "Exclusion must match despite keyword casing — seed transfer rules would otherwise categorize this")
    }

    func testNetWorthSnapshotKeepsOneRowPerDay() {
        let day = Date()
        NetWorthSnapshotService.record(value: 100, on: day, in: ctx)
        NetWorthSnapshotService.record(value: 250, on: day, in: ctx)
        let snaps = (try? ctx.fetch(FetchDescriptor<NetWorthSnapshot>())) ?? []
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.value, 250)
    }

    func testCategorizeAllAssignsFromSeededRules() {
        CategorySeed.seedIfNeeded(in: ctx)
        let txn = Transaction(id: "t1", posted: Date(), amount: -12, detail: "AMAZON MARKETPLACE", payee: "Amazon")
        ctx.insert(txn)

        CategorizationEngine.categorizeAll(in: ctx)

        XCTAssertNotNil(txn.category)
    }
}
