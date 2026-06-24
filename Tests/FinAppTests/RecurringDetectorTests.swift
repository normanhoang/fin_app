import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class RecurringDetectorTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    /// Build `count` charges spaced `gapDays` apart, ending `endDaysAgo` from now.
    private func series(merchant: String, amount: String, count: Int, gapDays: Int, endDaysAgo: Int = 0) {
        let end = cal.date(byAdding: .day, value: -endDaysAgo, to: Date())!
        for i in 0..<count {
            let posted = cal.date(byAdding: .day, value: -gapDays * i, to: end)!
            let t = Transaction(id: "\(merchant)-\(i)", posted: posted, amount: Decimal(string: amount)!,
                                detail: merchant, payee: merchant)
            ctx.insert(t)
        }
    }

    private var allTxns: [Transaction] { (try? ctx.fetch(FetchDescriptor<Transaction>())) ?? [] }

    func testDetectsMonthlySubscription() {
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30)
        let candidates = RecurringDetector.detectCandidates(from: allTxns)
        XCTAssertEqual(candidates.count, 1)
        let c = candidates[0]
        XCTAssertEqual(c.merchantName, "netflix")
        XCTAssertEqual(c.cadence, .monthly)
        XCTAssertEqual(c.expectedAmount, Decimal(string: "15.49"))
    }

    func testIgnoresTooFewOccurrences() {
        series(merchant: "Rare", amount: "-9.99", count: 2, gapDays: 30)
        XCTAssertTrue(RecurringDetector.detectCandidates(from: allTxns).isEmpty)
    }

    func testIgnoresIrregularSpacing() {
        // Gaps of wildly different sizes → no stable cadence.
        let days = [0, 3, 40, 47, 90]
        for (i, d) in days.enumerated() {
            let posted = cal.date(byAdding: .day, value: -d, to: Date())!
            ctx.insert(Transaction(id: "irr-\(i)", posted: posted, amount: -5, detail: "Random", payee: "Random"))
        }
        XCTAssertTrue(RecurringDetector.detectCandidates(from: allTxns).isEmpty)
    }

    func testDetectsMultipleMerchants() {
        series(merchant: "Spotify", amount: "-11.99", count: 4, gapDays: 30)
        series(merchant: "Gym", amount: "-40.00", count: 4, gapDays: 7)
        let candidates = RecurringDetector.detectCandidates(from: allTxns)
        XCTAssertEqual(Set(candidates.map(\.merchantName)), ["spotify", "gym"])
        XCTAssertEqual(candidates.first(where: { $0.merchantName == "gym" })?.cadence, .weekly)
    }

    func testNextDueProjectedFromLastSeen() {
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30, endDaysAgo: 10)
        let c = RecurringDetector.detectCandidates(from: allTxns)[0]
        let expected = cal.date(byAdding: .day, value: 30, to: c.lastSeen)!
        XCTAssertEqual(cal.startOfDay(for: c.nextDue), cal.startOfDay(for: expected))
    }

    func testIgnoresInflows() {
        series(merchant: "Payroll", amount: "2600.00", count: 5, gapDays: 14)
        XCTAssertTrue(RecurringDetector.detectCandidates(from: allTxns).isEmpty)
    }
}
