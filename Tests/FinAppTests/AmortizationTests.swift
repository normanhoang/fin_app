import XCTest
@testable import FinApp

final class AmortizationTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testOnePaymentAppliesRoundedInterest() {
        // 12%/yr → 1%/mo. 1000 + 10.00 interest − 100 = 910.00
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, payments: 1), 910)
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, payments: 2),
                       Decimal(string: "819.10"))
    }

    func testThirtyYearMortgageAfterTwelvePayments() {
        // $300k, 6%, P&I 1,798.65. Closed-form table says ≈296,315.99; per-month
        // cent rounding gives 296,316.00.
        let b = Amortization.balance(anchor: 300_000, annualRate: 6, pi: Decimal(string: "1798.65")!, payments: 12)
        XCTAssertEqual(b, Decimal(string: "296316.00"))
    }

    func testPaymentDatesStrictlyAfterAnchorDay() {
        // Anchor on a payment day: that day's payment is already in the balance.
        let dates = Amortization.paymentDates(after: date(2026, 2, 1, 10), through: date(2026, 2, 1, 12),
                                              paymentDay: 1, calendar: cal)
        XCTAssertTrue(dates.isEmpty)
    }

    func testPaymentDatesAcrossMonths() {
        let dates = Amortization.paymentDates(after: date(2026, 1, 15), through: date(2026, 3, 1, 9),
                                              paymentDay: 1, calendar: cal)
        XCTAssertEqual(dates, [date(2026, 2, 1), date(2026, 3, 1)])
        let before = Amortization.paymentDates(after: date(2026, 1, 15), through: date(2026, 2, 28),
                                               paymentDay: 1, calendar: cal)
        XCTAssertEqual(before, [date(2026, 2, 1)])
    }

    func testFebruaryPaymentDay28() {
        XCTAssertEqual(Amortization.nextPaymentDate(after: date(2026, 1, 31), paymentDay: 28, calendar: cal),
                       date(2026, 2, 28))
    }

    func testDatedBalanceUsesElapsedPayments() {
        let b = Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, paymentDay: 1,
                                     anchorDate: date(2026, 1, 15), asOf: date(2026, 3, 1, 9), calendar: cal)
        XCTAssertEqual(b, Decimal(string: "819.10"))
    }

    func testBalanceClampsAtZero() {
        // 150 → 51.50 → (51.50 + 0.52 − 100) < 0 → 0
        XCTAssertEqual(Amortization.balance(anchor: 150, annualRate: 12, pi: 100, payments: 5), 0)
    }

    func testPayoffDate() {
        XCTAssertEqual(Amortization.payoffDate(balance: 150, annualRate: 12, pi: 100, paymentDay: 1,
                                               from: date(2026, 1, 15), calendar: cal),
                       date(2026, 3, 1))
        // 30-year loan: P&I rounded down leaves $1.44 after 360, paid by payment 361.
        XCTAssertEqual(Amortization.payoffDate(balance: 300_000, annualRate: 6, pi: Decimal(string: "1798.65")!,
                                               paymentDay: 1, from: date(2026, 1, 15), calendar: cal),
                       date(2056, 2, 1))
    }

    func testPayoffNilWhenPaymentDoesNotCoverInterest() {
        XCTAssertFalse(Amortization.paymentCoversInterest(balance: 1000, annualRate: 12, pi: 10))
        XCTAssertTrue(Amortization.paymentCoversInterest(balance: 1000, annualRate: 12, pi: Decimal(string: "10.01")!))
        XCTAssertNil(Amortization.payoffDate(balance: 1000, annualRate: 12, pi: 10, paymentDay: 1,
                                             from: date(2026, 1, 15), calendar: cal))
        XCTAssertNil(Amortization.payoffDate(balance: 0, annualRate: 12, pi: 100, paymentDay: 1,
                                             from: date(2026, 1, 15), calendar: cal))
    }

    func testPayoffNilBeyondMaxPayments() {
        // Covers interest by one cent: would take far more than 1200 payments.
        XCTAssertNil(Amortization.payoffDate(balance: 300_000, annualRate: 6, pi: Decimal(string: "1500.01")!,
                                             paymentDay: 1, from: date(2026, 1, 15), calendar: cal))
    }

    func testZeroRate() {
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 0, pi: 100, payments: 3), 700)
    }
}
