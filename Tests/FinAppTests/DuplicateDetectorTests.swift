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

    // MARK: Review fixes

    /// Accounts from before `createdAt` existed are older than any dated one,
    /// even when the id tie-break would pick the other side.
    func testAccountWithoutCreatedAtIsOlder() {
        let old = acct("manual-z", "Mortgage", .loan, -412300, manual: true)
        let new = acct("manual-a", "Mortgage (Auto)", .loan, -411950, manual: true)
        new.createdAt = date(2026, 10, 14)
        let s = DuplicateDetector.suggestions(accounts: [old, new], firstSnapshotDay: [:], dismissed: [])
        XCTAssertEqual(s, [DuplicateSuggestion(flaggedID: "manual-z", matchID: "manual-a")])
    }

    func testEarlierCreatedAtWinsOverSnapshotDays() {
        let old = acct("manual-z", "Mortgage", .loan, -412300, manual: true)
        let new = acct("manual-a", "Mortgage (Auto)", .loan, -411950, manual: true)
        old.createdAt = date(2026, 10, 1)
        new.createdAt = date(2026, 10, 14)
        let days = ["manual-z": date(2026, 10, 14), "manual-a": date(2026, 10, 14)]
        let s = DuplicateDetector.suggestions(accounts: [old, new], firstSnapshotDay: days, dismissed: [])
        XCTAssertEqual(s, [DuplicateSuggestion(flaggedID: "manual-z", matchID: "manual-a")])
    }

    /// A just-added manual account keeps `source == .simplefin` until the launch
    /// migration runs; `isManual` is what marks it.
    func testFreshManualAccountCountsAsManual() {
        let fresh = acct("manual-a", "Mortgage (Auto)", .loan, -411950, manual: true)
        fresh.source = .simplefin
        let synced = acct("sf-b", "Mortgage", .loan, -412300, manual: false)
        XCTAssertTrue(DuplicateDetector.isLikelyDuplicate(fresh, synced))
    }

    func testGenericTypeNamesDoNotMatchByName() {
        let savings = acct("manual-a", "Savings", .cash, 500, manual: true)
        let ally = acct("sf-b", "Ally Savings", .cash, 40000, manual: false)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(savings, ally))
        let card = acct("manual-c", "Credit Card", .creditCard, -100, manual: true)
        let sapphire = acct("sf-d", "Chase Sapphire Credit Card", .creditCard, -5000, manual: false)
        XCTAssertFalse(DuplicateDetector.isLikelyDuplicate(card, sapphire))
    }

    func testSpecificWordsStillMatchBesideTypeWords() {
        let a = acct("manual-a", "Chase Checking", .cash, 100, manual: true)
        let b = acct("sf-b", "Chase Total Checking", .cash, 9000, manual: false)
        XCTAssertTrue(DuplicateDetector.isLikelyDuplicate(a, b))
    }

    /// Context helper: fetches snapshot days only to break ties, so views need no
    /// @Query over the whole snapshot table.
    func testContextSuggestionsUseSnapshotDaysForUndatedTies() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let a = acct("manual-a", "Mortgage", .loan, -412300, manual: true)
        let z = acct("manual-z", "Mortgage (Auto)", .loan, -411950, manual: true)
        ctx.insert(a)
        ctx.insert(z)
        ctx.insert(AccountBalanceSnapshot(accountId: "manual-z", day: date(2026, 7, 25), balance: -1))
        ctx.insert(AccountBalanceSnapshot(accountId: "manual-z", day: date(2026, 8, 1), balance: -1))
        ctx.insert(AccountBalanceSnapshot(accountId: "manual-a", day: date(2026, 10, 14), balance: -1))
        try ctx.save()

        XCTAssertEqual(DuplicateDetector.suggestions(accounts: [a, z], dismissed: [], in: ctx),
                       [DuplicateSuggestion(flaggedID: "manual-z", matchID: "manual-a")])
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
}
