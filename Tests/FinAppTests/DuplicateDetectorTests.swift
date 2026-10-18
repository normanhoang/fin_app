import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class DuplicateDetectorTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func acct(_ id: String, _ name: String, _ type: AccountType, _ balance: Decimal,
                      manual: Bool) -> Account {
        let a = Account(id: id, org: "Test", name: name, currency: "USD", balance: balance,
                        balanceDate: Date(), typeRaw: type.rawValue, isManual: manual)
        a.source = manual ? .manual : .simplefin
        return a
    }

    func testMortgageAndAutoMortgageMatchByName() {
        let a = acct("manual-a", "Mortgage", .loan, -412300, manual: true)
        let b = acct("manual-b", "Mortgage (Auto)", .loan, -380000, manual: true)
        XCTAssertTrue(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testCloseBalancesMatch() {
        let a = acct("manual-a", "Old Checking", .cash, 4812, manual: true)
        let b = acct("sf-b", "Chase Total", .cash, 4950, manual: false)
        XCTAssertTrue(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testDifferentTypesNeverMatch() {
        let a = acct("manual-a", "Mortgage", .loan, -1000, manual: true)
        let b = acct("manual-b", "Mortgage", .creditCard, -1000, manual: true)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testTwoSyncedAccountsNeverFlagged() {
        let a = acct("sf-a", "Chase Checking", .cash, 4812, manual: false)
        let b = acct("sf-b", "Chase Checking 2", .cash, 4813, manual: false)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testZeroBalancesDoNotMatchOnBalance() {
        let a = acct("manual-a", "Amex", .creditCard, 0, manual: true)
        let b = acct("manual-b", "Visa", .creditCard, 0, manual: true)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testDisjointNamesFarBalancesNoMatch() {
        let a = acct("manual-a", "Checking", .cash, 100, manual: true)
        let b = acct("manual-b", "Savings", .cash, 9000, manual: true)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testFlagsManualOverSynced() {
        let a = acct("sf-a", "Chase Total", .cash, 4950, manual: false)
        let b = acct("manual-b", "Old Checking", .cash, 4812, manual: true)
        let s = DuplicateDetector.suggestions(accounts: [a, b], firstSnapshotDay: [:], dismissed: [])
        XCTAssertEqual(s, [DuplicateSuggestion(flaggedID: "manual-b", matchID: "sf-a")])
    }

    func testFlagsOlderWhenBothManual() {
        let a = acct("manual-z", "Mortgage", .loan, -412300, manual: true)
        let b = acct("manual-a", "Mortgage (Auto)", .loan, -411950, manual: true)
        let days = ["manual-z": date(2026, 7, 25), "manual-a": date(2026, 10, 14)]
        let s = DuplicateDetector.suggestions(accounts: [a, b], firstSnapshotDay: days, dismissed: [])
        XCTAssertEqual(s, [DuplicateSuggestion(flaggedID: "manual-z", matchID: "manual-a")])
        // An account with no snapshots counts as newest.
        let s2 = DuplicateDetector.suggestions(accounts: [a, b],
                                               firstSnapshotDay: ["manual-a": date(2026, 10, 14)],
                                               dismissed: [])
        XCTAssertEqual(s2, [DuplicateSuggestion(flaggedID: "manual-a", matchID: "manual-z")])
    }

    func testTieBreaksByID() {
        let a = acct("manual-b", "Mortgage", .loan, -412300, manual: true)
        let b = acct("manual-a", "Mortgage (Auto)", .loan, -411950, manual: true)
        let s = DuplicateDetector.suggestions(accounts: [a, b], firstSnapshotDay: [:], dismissed: [])
        XCTAssertEqual(s, [DuplicateSuggestion(flaggedID: "manual-a", matchID: "manual-b")])
    }

    func testDismissedPairSuppressed() {
        let a = acct("manual-a", "Mortgage", .loan, -412300, manual: true)
        let b = acct("manual-b", "Mortgage (Auto)", .loan, -411950, manual: true)
        let s = DuplicateDetector.suggestions(
            accounts: [a, b], firstSnapshotDay: [:],
            dismissed: [DuplicateDetector.pairKey("manual-a", "manual-b")])
        XCTAssertEqual(s, [])
    }

    func testOneSuggestionPerFlaggedPicksClosestBalance() {
        let old = acct("manual-old", "Mortgage", .loan, -412300, manual: true)
        let auto = acct("manual-auto", "Mortgage (Auto)", .loan, -411950, manual: true)
        let other = acct("manual-two", "Mortgage 2", .loan, -300000, manual: true)
        let days = ["manual-old": date(2026, 7, 25), "manual-auto": date(2026, 10, 14),
                    "manual-two": date(2026, 10, 1)]
        let s = DuplicateDetector.suggestions(accounts: [old, auto, other], firstSnapshotDay: days,
                                              dismissed: [])
        XCTAssertEqual(s.filter { $0.flaggedID == "manual-old" },
                       [DuplicateSuggestion(flaggedID: "manual-old", matchID: "manual-auto")])
    }

    func testAutoLoanAndStudentLoanDoNotMatch() {
        let a = acct("manual-a", "Auto Loan", .loan, -18000, manual: true)
        let b = acct("manual-b", "Student Loan", .loan, -42000, manual: true)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    func testPairKeyIsOrderIndependent() {
        XCTAssertEqual(DuplicateDetector.pairKey("b", "a"), "a|b")
        XCTAssertEqual(DuplicateDetector.pairKey("a", "b"), "a|b")
    }

    func testCandidatesSameTypeClosestFirst() {
        let old = acct("manual-old", "Mortgage", .loan, -412300, manual: true)
        let auto = acct("manual-auto", "Mortgage (Auto)", .loan, -411950, manual: true)
        let heloc = acct("manual-h", "HELOC", .loan, -38200, manual: true)
        let card = acct("manual-c", "Card", .creditCard, -400000, manual: true)
        XCTAssertEqual(DuplicateDetector.candidates(for: old, among: [card, heloc, old, auto]).map(\.id),
                       ["manual-auto", "manual-h"])
    }

    func testDismissPersistsOnceAndSuppresses() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        DismissedDuplicate.dismiss("manual-a", "manual-b", in: ctx)
        DismissedDuplicate.dismiss("manual-a", "manual-b", in: ctx)
        DismissedDuplicate.dismiss("manual-b", "manual-a", in: ctx)
        let rows = try ctx.fetch(FetchDescriptor<DismissedDuplicate>())
        XCTAssertEqual(rows.count, 1)

        let a = acct("manual-a", "Mortgage", .loan, -412300, manual: true)
        let b = acct("manual-b", "Mortgage (Auto)", .loan, -411950, manual: true)
        XCTAssertEqual(DuplicateDetector.suggestions(accounts: [a, b], firstSnapshotDay: [:],
                                                     dismissed: Set(rows.map(\.key))), [])
    }

    func testFirstSnapshotDays() {
        let rows = [AccountBalanceSnapshot(accountId: "a", day: date(2026, 8, 2), balance: 1),
                    AccountBalanceSnapshot(accountId: "a", day: date(2026, 7, 25), balance: 1),
                    AccountBalanceSnapshot(accountId: "b", day: date(2026, 9, 1), balance: 1)]
        XCTAssertEqual(DuplicateDetector.firstSnapshotDays(rows),
                       ["a": date(2026, 7, 25), "b": date(2026, 9, 1)])
    }
}
