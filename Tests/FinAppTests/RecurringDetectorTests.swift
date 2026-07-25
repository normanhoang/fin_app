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

    func testRefreshKeepsUserSetNextDue() {
        // Last charge 10 days ago; auto-projection would say +30d from lastSeen.
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30, endDaysAgo: 10)
        // User picked a next-due date in the future, after the last charge.
        let userDate = cal.date(byAdding: .day, value: 5, to: Date())!
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: Decimal(string: "15.49")!,
                                 cadence: .monthly, lastSeen: Date(), nextDue: userDate,
                                 nextDueSetByUser: true))
        try? ctx.save()

        RecurringDetector.refresh(in: ctx, calendar: cal)

        let bill = ((try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? [])
            .first { $0.merchantName == "netflix" }
        XCTAssertEqual(bill?.nextDue, userDate, "User-set next due must survive refresh")
        XCTAssertTrue(bill?.nextDueSetByUser == true)
    }

    func testRefreshResumesProjectionAfterChargeOnOrAfterUserDate() {
        // Last charge is TODAY — on/after the user's stale date below.
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30, endDaysAgo: 0)
        let staleUserDate = cal.date(byAdding: .day, value: -3, to: Date())!
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: Decimal(string: "15.49")!,
                                 cadence: .monthly, lastSeen: Date(), nextDue: staleUserDate,
                                 nextDueSetByUser: true))
        try? ctx.save()

        RecurringDetector.refresh(in: ctx, calendar: cal)

        let bill = ((try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? [])
            .first { $0.merchantName == "netflix" }
        XCTAssertEqual(bill?.nextDueSetByUser, false, "Override clears once a charge posts on/after it")
        XCTAssertNotEqual(bill?.nextDue, staleUserDate, "Projection resumes from detection")
    }

    // MARK: - Price-change detection

    /// Charges at `amounts`, oldest first, spaced `gapDays` apart ending today.
    private func priceSeries(merchant: String, amounts: [String], gapDays: Int = 30) {
        for (i, amount) in amounts.enumerated() {
            let posted = cal.date(byAdding: .day, value: -gapDays * (amounts.count - 1 - i), to: Date())!
            ctx.insert(Transaction(id: "\(merchant)-p\(i)", posted: posted,
                                   amount: Decimal(string: amount)!, detail: merchant, payee: merchant))
        }
    }

    func testDetectsPriceIncrease() {
        priceSeries(merchant: "Netflix", amounts: ["-13.99", "-13.99", "-13.99", "-15.49"])
        let c = RecurringDetector.detectCandidates(from: allTxns, calendar: cal)[0]
        XCTAssertEqual(c.previousAmount, Decimal(string: "13.99"))
        XCTAssertEqual(c.expectedAmount, Decimal(string: "15.49"), "Newest amount is the real obligation")
        XCTAssertNotNil(c.amountChangedAt)
    }

    func testNoPriceChangeWithinTwoPercent() {
        priceSeries(merchant: "Gym", amounts: ["-100.00", "-100.00", "-100.00", "-101.00"])
        let c = RecurringDetector.detectCandidates(from: allTxns, calendar: cal)[0]
        XCTAssertNil(c.previousAmount)
        XCTAssertEqual(c.expectedAmount, Decimal(string: "100.00"))
    }

    func testPriceChangeRequiresStablePriorCharges() {
        // The three charges before the newest don't share one amount → no flag.
        priceSeries(merchant: "Water", amounts: ["-10.00", "-11.00", "-10.00", "-15.00"])
        let c = RecurringDetector.detectCandidates(from: allTxns, calendar: cal)[0]
        XCTAssertNil(c.previousAmount)
        XCTAssertNil(c.amountChangedAt)
    }

    func testRefreshStoresPriceChangeOnBill() {
        priceSeries(merchant: "Netflix", amounts: ["-13.99", "-13.99", "-13.99", "-15.49"])
        RecurringDetector.refresh(in: ctx, calendar: cal)
        let bill = ((try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? [])
            .first { $0.merchantName == "netflix" }
        XCTAssertEqual(bill?.previousAmount, Decimal(string: "13.99"))
        XCTAssertEqual(bill?.expectedAmount, Decimal(string: "15.49"))
    }

    func testRefreshClearsPriceChangeOnceStable() {
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30)
        let bill = RecurringBill(merchantName: "netflix", expectedAmount: Decimal(string: "15.49")!,
                                 cadence: .monthly, lastSeen: Date())
        bill.previousAmount = Decimal(string: "13.99")
        bill.amountChangedAt = Date()
        ctx.insert(bill)
        try? ctx.save()

        RecurringDetector.refresh(in: ctx, calendar: cal)

        let stored = ((try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? [])
            .first { $0.merchantName == "netflix" }
        XCTAssertNil(stored?.previousAmount, "Alert clears once charges are stable again")
        XCTAssertNil(stored?.amountChangedAt)
    }

    func testRefreshDoesNotResurrectDismissedBill() {
        // A merchant that detection will find...
        series(merchant: "Netflix", amount: "-15.49", count: 5, gapDays: 30)
        // ...but the user already dismissed it (merchant stored normalized).
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: Decimal(string: "15.49")!,
                                 cadence: .monthly, lastSeen: Date(), dismissed: true))
        try? ctx.save()

        RecurringDetector.refresh(in: ctx, calendar: cal)

        let bills = (try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? []
        let netflix = bills.filter { $0.merchantName == "netflix" }
        XCTAssertEqual(netflix.count, 1, "Dismissed merchant must not be re-inserted")
        XCTAssertTrue(netflix.first?.dismissed == true, "Dismissal must persist across refresh")
    }
}
