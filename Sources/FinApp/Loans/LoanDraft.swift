import Foundation

/// Text-field state for the loan schedule form, parsed and validated into
/// `Inputs`. Pure value type so validation is unit-tested without UI.
struct LoanDraft: Equatable {
    var balanceText = ""
    var asOf = Date()
    var rateText = ""
    var totalText = ""
    var escrowText = ""
    var paymentDay = 1
    var principalText = ""
    var termYearsText = ""
    var hasStartDate = false
    var startDate = Date()

    struct Inputs: Equatable {
        var balance: Decimal
        var asOf: Date
        var annualRate: Decimal
        var totalPayment: Decimal
        var escrow: Decimal
        var paymentDay: Int
        var originalPrincipal: Decimal?
        var termMonths: Int?
        var startDate: Date?

        var pi: Decimal { totalPayment - escrow }
    }

    enum Problem: Error, Equatable {
        case incomplete, futureDate, escrowTooLarge, paymentBelowInterest

        /// nil for `.incomplete`: Save is just disabled until required fields are filled.
        var message: String? {
            switch self {
            case .incomplete: nil
            case .futureDate: "The as-of date can't be in the future."
            case .escrowTooLarge: "Escrow must be less than the monthly payment."
            case .paymentBelowInterest: "Payment minus escrow doesn't cover the monthly interest, so the balance would never go down."
            }
        }
    }

    init() {}

    /// Prefill for editing: the balance is the schedule's computed balance as of `now`.
    init(schedule: LoanSchedule, now: Date = Date(), calendar: Calendar = .current) {
        balanceText = Self.text(schedule.balance(asOf: now, calendar: calendar))
        asOf = now
        rateText = Self.text(schedule.annualRate)
        totalText = Self.text(schedule.totalPayment)
        escrowText = Self.text(schedule.escrow)
        paymentDay = schedule.paymentDay
        principalText = schedule.originalPrincipal.map(Self.text) ?? ""
        termYearsText = schedule.termMonths.map { String($0 / 12) } ?? ""
        hasStartDate = schedule.startDate != nil
        startDate = schedule.startDate ?? now
    }

    static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

    private static func number(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Decimal(string: trimmed, locale: .current)
    }

    var isValid: Bool {
        if case .success = validate() { true } else { false }
    }

    func validate(now: Date = Date()) -> Result<Inputs, Problem> {
        guard let balance = Self.number(balanceText), balance > 0,
              let rate = Self.number(rateText), rate >= 0,
              let total = Self.number(totalText), total > 0 else { return .failure(.incomplete) }
        let escrow = Self.number(escrowText) ?? 0
        guard escrow >= 0 else { return .failure(.incomplete) }
        guard escrow < total else { return .failure(.escrowTooLarge) }
        guard asOf <= now else { return .failure(.futureDate) }
        guard Amortization.paymentCoversInterest(balance: balance, annualRate: rate, pi: total - escrow) else {
            return .failure(.paymentBelowInterest)
        }
        let principal = Self.number(principalText).flatMap { $0 > 0 ? $0 : nil }
        let years = Int(termYearsText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        return .success(Inputs(
            balance: balance, asOf: asOf, annualRate: rate, totalPayment: total, escrow: escrow,
            paymentDay: min(max(paymentDay, 1), 28), originalPrincipal: principal,
            termMonths: years.map { $0 * 12 }, startDate: hasStartDate ? startDate : nil))
    }
}

extension LoanDraft.Inputs {
    /// "P&I $1,798.65 · next payment Nov 1 · payoff ~Mar 2052"
    func preview(now: Date = Date(), calendar: Calendar = .current) -> String {
        let current = Amortization.balance(anchor: balance, annualRate: annualRate, pi: pi,
                                           paymentDay: paymentDay, anchorDate: asOf,
                                           asOf: now, calendar: calendar)
        let next = Amortization.nextPaymentDate(after: now, paymentDay: paymentDay, calendar: calendar)
        var parts = ["P&I \(Money.string(pi))",
                     "next payment \(next.formatted(.dateTime.month(.abbreviated).day()))"]
        if let payoff = Amortization.payoffDate(balance: current, annualRate: annualRate, pi: pi,
                                                paymentDay: paymentDay, from: now, calendar: calendar) {
            parts.append("payoff ~\(payoff.formatted(.dateTime.month(.abbreviated).year()))")
        }
        return parts.joined(separator: " · ")
    }
}
