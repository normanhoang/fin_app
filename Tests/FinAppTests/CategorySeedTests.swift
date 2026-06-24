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
