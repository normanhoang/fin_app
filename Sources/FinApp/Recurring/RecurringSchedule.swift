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
}
