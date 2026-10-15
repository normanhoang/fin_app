import Foundation
import SwiftData

/// Payment schedule for a manual loan whose balance the app computes
/// (`LoanUpdater`). Projects forward from a known anchor balance; see
/// `Amortization`. Owned by its `Account` (cascade delete).
@Model
final class LoanSchedule {
    /// Annual rate in percent, e.g. 6.25.
    var annualRate: Decimal
    /// Total monthly payment, including escrow.
    var totalPayment: Decimal
    /// Taxes/insurance portion of `totalPayment`; doesn't reduce the balance.
    var escrow: Decimal
    /// Day of month payments post (1...28).
    var paymentDay: Int
    /// Amount owed (positive) as of `anchorDate`.
    var anchorBalance: Decimal
    var anchorDate: Date
    /// Display-only loan details.
    var originalPrincipal: Decimal? = nil
    var termMonths: Int? = nil
    var startDate: Date? = nil
    var account: Account? = nil

    init(inputs: LoanDraft.Inputs) {
        annualRate = inputs.annualRate
        totalPayment = inputs.totalPayment
        escrow = inputs.escrow
        paymentDay = inputs.paymentDay
        anchorBalance = inputs.balance
        anchorDate = inputs.asOf
        originalPrincipal = inputs.originalPrincipal
        termMonths = inputs.termMonths
        startDate = inputs.startDate
    }

    /// Overwrite every field from an edited form; re-anchors to its balance/date.
    func apply(_ inputs: LoanDraft.Inputs) {
        annualRate = inputs.annualRate
        totalPayment = inputs.totalPayment
        escrow = inputs.escrow
        paymentDay = inputs.paymentDay
        anchorBalance = inputs.balance
        anchorDate = inputs.asOf
        originalPrincipal = inputs.originalPrincipal
        termMonths = inputs.termMonths
        startDate = inputs.startDate
    }

    /// Principal & interest — the part of the payment that amortizes.
    var pi: Decimal { totalPayment - escrow }

    func balance(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        Amortization.balance(anchor: anchorBalance, annualRate: annualRate, pi: pi,
                             paymentDay: paymentDay, anchorDate: anchorDate,
                             asOf: date, calendar: calendar)
    }

    func lastPaymentDate(asOf date: Date, calendar: Calendar = .current) -> Date? {
        Amortization.paymentDates(after: anchorDate, through: date,
                                  paymentDay: paymentDay, calendar: calendar).last
    }

    func nextPaymentDate(asOf date: Date, calendar: Calendar = .current) -> Date {
        Amortization.nextPaymentDate(after: date, paymentDay: paymentDay, calendar: calendar)
    }

    func payoffDate(asOf date: Date, calendar: Calendar = .current) -> Date? {
        Amortization.payoffDate(balance: balance(asOf: date, calendar: calendar),
                                annualRate: annualRate, pi: pi, paymentDay: paymentDay,
                                from: date, calendar: calendar)
    }

    /// Restart the projection from a known balance (extra payment, manual edit).
    func reanchor(to owed: Decimal, at date: Date) {
        anchorBalance = max(0, owed)
        anchorDate = date
    }
}
