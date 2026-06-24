import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class RecurringStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    private var bills: [RecurringBill] { (try? ctx.fetch(FetchDescriptor<RecurringBill>())) ?? [] }

    func testSetRecurringTwiceDoesNotDuplicate() {
        RecurringStore.setRecurring(merchant: "netflix", amount: 15, cadence: .monthly,
                                    lastSeen: Date(), category: nil, in: ctx)
        RecurringStore.setRecurring(merchant: "netflix", amount: 16, cadence: .monthly,
                                    lastSeen: Date(), category: nil, in: ctx)
        XCTAssertEqual(bills.count, 1)
        XCTAssertTrue(bills[0].confirmed)
        XCTAssertEqual(bills[0].expectedAmount, 16)
    }

    func testSetRecurringPromotesDetectedCandidate() {
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: 15, cadence: .monthly,
                                 lastSeen: Date(), confirmed: false))
        try? ctx.save()
        RecurringStore.setRecurring(merchant: "netflix", amount: 15, cadence: .monthly,
                                    lastSeen: Date(), category: nil, in: ctx)
        XCTAssertEqual(bills.count, 1, "Should promote the candidate, not add a second row")
        XCTAssertTrue(bills[0].confirmed)
    }

    func testSetRecurringUndismisses() {
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: 15, cadence: .monthly,
                                 lastSeen: Date(), confirmed: false, dismissed: true))
        try? ctx.save()
        RecurringStore.setRecurring(merchant: "netflix", amount: 15, cadence: .monthly,
                                    lastSeen: Date(), category: nil, in: ctx)
        XCTAssertEqual(bills.count, 1)
        XCTAssertFalse(bills[0].dismissed)
        XCTAssertTrue(bills[0].confirmed)
    }

    func testDedupeCollapsesConfirmedAndDetectedPair() {
        // A confirmed bill and a detected candidate for the same merchant.
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: 15, cadence: .monthly,
                                 lastSeen: Date(), confirmed: true))
        ctx.insert(RecurringBill(merchantName: "netflix", expectedAmount: 15, cadence: .monthly,
                                 lastSeen: Date(), confirmed: false))
        try? ctx.save()

        RecurringStore.dedupe(in: ctx)

        XCTAssertEqual(bills.count, 1, "Duplicate merchant should collapse to one row")
        XCTAssertTrue(bills[0].confirmed, "Keeps the confirmed bill")
    }
}
