import Foundation

/// Fixed-rate amortization projected forward from a known (anchor) balance.
/// Pure — no SwiftData. Interest is rounded to cents each payment, like a
/// servicer statement.
enum Amortization {
    /// Upper bound on projected payments (100 years) so bad input can't loop forever.
    static let maxPayments = 1200

    static func monthlyRate(_ annualRate: Decimal) -> Decimal { annualRate / 100 / 12 }

    static func roundCents(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// True when `pi` exceeds the next payment's interest, so the balance falls.
    static func paymentCoversInterest(balance: Decimal, annualRate: Decimal, pi: Decimal) -> Bool {
        pi > roundCents(balance * monthlyRate(annualRate))
    }

    /// First payment date (start of day, on `paymentDay`) strictly after `date`'s day.
    static func nextPaymentDate(after date: Date, paymentDay: Int, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        var comps = calendar.dateComponents([.year, .month], from: day)
        comps.day = paymentDay
        guard let thisMonth = calendar.date(from: comps) else { return day }
        if thisMonth > day { return thisMonth }
        return calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth
    }

    /// Payment dates strictly after `anchorDate`'s day, up to and including `asOf`.
    static func paymentDates(after anchorDate: Date, through asOf: Date,
                             paymentDay: Int, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var next = nextPaymentDate(after: anchorDate, paymentDay: paymentDay, calendar: calendar)
        while next <= asOf, dates.count < maxPayments {
            dates.append(next)
            guard let following = calendar.date(byAdding: .month, value: 1, to: next) else { break }
            next = following
        }
        return dates
    }

    /// Balance after `payments` monthly payments of `pi`. Never below 0.
    static func balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, payments: Int) -> Decimal {
        let rate = monthlyRate(annualRate)
        var balance = anchor
        for _ in 0..<max(0, payments) where balance > 0 {
            let interest = roundCents(balance * rate)
            balance = max(0, balance - (pi - interest))
        }
        return balance
    }

    /// Balance as of `asOf`, applying each payment date after `anchorDate`.
    static func balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, paymentDay: Int,
                        anchorDate: Date, asOf: Date, calendar: Calendar) -> Decimal {
        let count = paymentDates(after: anchorDate, through: asOf,
                                 paymentDay: paymentDay, calendar: calendar).count
        return balance(anchor: anchor, annualRate: annualRate, pi: pi, payments: count)
    }

    /// Date of the payment that brings `balance` to 0, counting from the first
    /// payment after `from`. nil when already paid off, when the payment never
    /// covers interest, or beyond `maxPayments`.
    static func payoffDate(balance: Decimal, annualRate: Decimal, pi: Decimal,
                           paymentDay: Int, from: Date, calendar: Calendar) -> Date? {
        guard balance > 0,
              paymentCoversInterest(balance: balance, annualRate: annualRate, pi: pi) else { return nil }
        var remaining = balance
        var date = nextPaymentDate(after: from, paymentDay: paymentDay, calendar: calendar)
        for _ in 0..<maxPayments {
            remaining = self.balance(anchor: remaining, annualRate: annualRate, pi: pi, payments: 1)
            if remaining == 0 { return date }
            guard let following = calendar.date(byAdding: .month, value: 1, to: date) else { return nil }
            date = following
        }
        return nil
    }
}
