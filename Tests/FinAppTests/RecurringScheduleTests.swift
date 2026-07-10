import XCTest
@testable import FinApp

final class RecurringScheduleTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func month(_ y: Int, _ m: Int) -> DateInterval {
        cal.dateInterval(of: .month, for: date(y, m, 15))!
    }

    private func days(_ dates: [Date]) -> [Int] {
        dates.map { cal.component(.day, from: $0) }
    }

    func testMonthlyMidMonthOneOccurrence() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 7, 15), cadence: .monthly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertEqual(days(hits), [15])
    }

    func testMonthlyJan31ClampsToFeb28() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 1, 31), cadence: .monthly,
                                                 in: month(2026, 2), calendar: cal)
        XCTAssertEqual(days(hits), [28], "2026 is not a leap year — Jan 31 anchor should land on Feb 28")
    }

    func testWeeklyAnchorBeforeMonthAligns() {
        // Anchor 3 weeks before July: occurrences inside July stay on the same weekday.
        let anchor = date(2026, 6, 10) // a Wednesday
        let hits = RecurringSchedule.occurrences(anchor: anchor, cadence: .weekly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertEqual(days(hits), [1, 8, 15, 22, 29])
        for hit in hits {
            XCTAssertEqual(cal.component(.weekday, from: hit), cal.component(.weekday, from: anchor))
        }
    }

    func testBiweeklyAcrossMonthBoundary() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 6, 25), cadence: .biweekly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertEqual(days(hits), [9, 23])
    }

    func testAnchorPastIntervalIsEmpty() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 8, 1), cadence: .monthly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertTrue(hits.isEmpty)
    }

    func testOverdueAnchorInsideIntervalIncluded() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 7, 3), cadence: .monthly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertEqual(days(hits), [3])
    }

    func testYearlyNonAnniversaryMonthIsEmpty() {
        let hits = RecurringSchedule.occurrences(anchor: date(2026, 3, 12), cadence: .yearly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertTrue(hits.isEmpty)
    }

    func testNextOccurrenceOverdueMonthlyRollsForward() {
        // Stored nextDue Jul 2, today Jul 4 -> first future occurrence is Aug 2.
        let next = RecurringSchedule.nextOccurrence(onOrAfter: date(2026, 7, 4),
                                                    anchor: date(2026, 7, 2),
                                                    cadence: .monthly, calendar: cal)
        XCTAssertEqual(next, date(2026, 8, 2))
    }

    func testNextOccurrenceDueTodayStaysToday() {
        let next = RecurringSchedule.nextOccurrence(onOrAfter: date(2026, 7, 4),
                                                    anchor: date(2026, 7, 4),
                                                    cadence: .monthly, calendar: cal)
        XCTAssertEqual(next, date(2026, 7, 4))
    }

    func testNextOccurrenceFutureAnchorUnchanged() {
        let next = RecurringSchedule.nextOccurrence(onOrAfter: date(2026, 7, 4),
                                                    anchor: date(2026, 7, 20),
                                                    cadence: .weekly, calendar: cal)
        XCTAssertEqual(next, date(2026, 7, 20))
    }

    func testNextOccurrenceMonthlyJan31Clamps() {
        // Jan 31 anchor asked for the next occurrence in February clamps to Feb 28.
        let next = RecurringSchedule.nextOccurrence(onOrAfter: date(2026, 2, 1),
                                                    anchor: date(2026, 1, 31),
                                                    cadence: .monthly, calendar: cal)
        XCTAssertEqual(next, date(2026, 2, 28))
    }

    func testWeeklyFarPastAnchorTerminatesAndAligns() {
        let anchor = date(2021, 7, 7) // ~5 years back
        let hits = RecurringSchedule.occurrences(anchor: anchor, cadence: .weekly,
                                                 in: month(2026, 7), calendar: cal)
        XCTAssertEqual(hits.count, 5)
        for hit in hits {
            XCTAssertEqual(cal.component(.weekday, from: hit), cal.component(.weekday, from: anchor))
        }
    }
}
