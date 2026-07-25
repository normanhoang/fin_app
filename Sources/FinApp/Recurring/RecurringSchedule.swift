import Foundation

/// Projects a bill's future occurrence dates for calendar display. Steps are
/// calendar-aware (monthly = +1 month, not +30 days) so a bill anchored on
/// Jan 31 lands on Feb 28 instead of drifting — unlike `Cadence.days`, which
/// the detector uses only to compute the single stored `nextDue`.
enum RecurringSchedule {

    /// All projected occurrences within `interval`, stepping forward from
    /// `anchor` (the stored `nextDue`). An overdue anchor that falls inside
    /// the interval is included. `interval.end` is treated as exclusive —
    /// a month interval from `Calendar` ends at the start of the next month.
    static func occurrences(anchor: Date, cadence: Cadence, in interval: DateInterval,
                            calendar: Calendar = .current) -> [Date] {
        guard anchor < interval.end else { return [] }
        var date = anchor
        var dates: [Date] = []
        // Cap iterations so a far-past anchor can't spin (e.g. a weekly bill
        // years stale still needs only ~52 steps/year to catch up).
        for _ in 0..<1000 {
            if date >= interval.end { break }
            if date >= interval.start { dates.append(date) }
            guard let next = advance(date, by: cadence, calendar: calendar) else { break }
            date = next
        }
        return dates
    }

    static func advance(_ date: Date, by cadence: Cadence, calendar: Calendar) -> Date? {
        switch cadence {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly: calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: calendar.date(byAdding: .month, value: 3, to: date)
        case .yearly: calendar.date(byAdding: .year, value: 1, to: date)
        }
    }

    /// First occurrence on/after `date`, stepping calendar-aware from `anchor`.
    /// Returns `anchor` unchanged if it is already on/after `date`.
    static func nextOccurrence(onOrAfter date: Date, anchor: Date, cadence: Cadence,
                               calendar: Calendar = .current) -> Date {
        let floor = calendar.startOfDay(for: date)
        var result = anchor
        // Same runaway cap as occurrences().
        for _ in 0..<1000 {
            if result >= floor { break }
            guard let next = advance(result, by: cadence, calendar: calendar) else { break }
            result = next
        }
        return result
    }
}

extension RecurringBill {
    /// Stored `nextDue` rolled forward to today-or-later for display and sort.
    /// The stored value stays untouched — it only moves on sync or user edit,
    /// so it can be days in the past when no new charge has posted yet.
    var effectiveNextDue: Date? {
        nextDue.map { RecurringSchedule.nextOccurrence(onOrAfter: .now, anchor: $0, cadence: cadence) }
    }

    /// Cost normalized to a monthly figure (annual ÷ 12, weekly × 52/12, …)
    /// for the Recurring summary card.
    var monthlyEquivalent: Decimal {
        switch cadence {
        case .weekly: expectedAmount * 52 / 12
        case .biweekly: expectedAmount * 26 / 12
        case .monthly: expectedAmount
        case .quarterly: expectedAmount / 3
        case .yearly: expectedAmount / 12
        }
    }

    /// How many charges land in a year, for the price-alert "+$X/yr" figure.
    var chargesPerYear: Decimal {
        switch cadence {
        case .weekly: 52
        case .biweekly: 26
        case .monthly: 12
        case .quarterly: 4
        case .yearly: 1
        }
    }

    /// True when detection saw the newest charge rise above the stable amount and
    /// the user hasn't acknowledged this particular amount yet.
    var priceWentUp: Bool {
        guard let previous = previousAmount, expectedAmount > previous else { return false }
        return priceAckAmount != expectedAmount
    }
}
