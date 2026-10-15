import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class LoanDraftTests: XCTestCase {
    private func validDraft() -> LoanDraft {
        var d = LoanDraft()
        d.balanceText = "1000"
        d.asOf = Date(timeIntervalSince1970: 1_767_614_400) // 2026-01-05 12:00 UTC — mid-month in any time zone
        d.rateText = "12"
        d.totalText = "150"
        d.escrowText = "50"
        d.paymentDay = 1
        return d
    }

    private let now = Date(timeIntervalSince1970: 1_768_000_000) // 2026-01-10

    func testValidDraftProducesInputs() throws {
        let inputs = try validDraft().validate(now: now).get()
        XCTAssertEqual(inputs.balance, 1000)
        XCTAssertEqual(inputs.pi, 100)
        XCTAssertNil(inputs.termMonths)
        XCTAssertNil(inputs.startDate)
    }

    func testBlankEscrowIsZero() throws {
        var d = validDraft(); d.escrowText = ""
        XCTAssertEqual(try d.validate(now: now).get().escrow, 0)
    }

    func testMissingRequiredIsIncomplete() {
        var d = validDraft(); d.rateText = ""
        XCTAssertEqual(d.validate(now: now), .failure(.incomplete))
        XCTAssertNil(LoanDraft.Problem.incomplete.message)
        XCTAssertFalse(d.isValid)
    }

    func testEscrowMustBeBelowTotal() {
        var d = validDraft(); d.escrowText = "150"
        XCTAssertEqual(d.validate(now: now), .failure(.escrowTooLarge))
    }

    func testPaymentMustCoverInterest() {
        var d = validDraft(); d.totalText = "60" // pi 10 == interest 10
        XCTAssertEqual(d.validate(now: now), .failure(.paymentBelowInterest))
        XCTAssertNotNil(LoanDraft.Problem.paymentBelowInterest.message)
    }

    func testFutureAsOfRejected() {
        var d = validDraft(); d.asOf = now.addingTimeInterval(86_400)
        XCTAssertEqual(d.validate(now: now), .failure(.futureDate))
    }

    func testOptionalFields() throws {
        var d = validDraft()
        d.principalText = "300000"; d.termYearsText = "30"; d.hasStartDate = true
        let inputs = try d.validate(now: now).get()
        XCTAssertEqual(inputs.originalPrincipal, 300_000)
        XCTAssertEqual(inputs.termMonths, 360)
        XCTAssertEqual(inputs.startDate, d.startDate)
    }

    func testScheduleRoundTripAndPrefill() throws {
        let container = AppSchema.makeInMemoryContainer() // keep alive
        let ctx = container.mainContext
        let inputs = try validDraft().validate(now: now).get()
        let schedule = LoanSchedule(inputs: inputs)
        ctx.insert(schedule)
        try ctx.save()
        XCTAssertEqual(schedule.pi, 100)
        XCTAssertEqual(schedule.anchorBalance, 1000)

        // Prefill uses today's computed balance (no payment due between Jan 5 and Jan 10).
        let prefill = LoanDraft(schedule: schedule, now: now)
        XCTAssertEqual(prefill.balanceText, "1000")
        XCTAssertEqual(prefill.rateText, "12")
        XCTAssertEqual(prefill.escrowText, "50")
        XCTAssertEqual(prefill.asOf, now)
    }

    func testPreviewMentionsPIAndPayoff() throws {
        let preview = try validDraft().validate(now: now).get().preview(now: now)
        XCTAssertTrue(preview.hasPrefix("P&I "), preview)
        XCTAssertTrue(preview.contains("next payment"), preview)
        XCTAssertTrue(preview.contains("payoff"), preview)
    }
}
