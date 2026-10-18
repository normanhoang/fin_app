import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class AccountMergeTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func oct(_ d: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d))!
    }

    private func account(_ ctx: ModelContext, _ id: String, _ type: AccountType = .cash,
                         _ balance: Decimal = 100) -> Account {
        let a = Account(id: id, org: "Manual", name: id, currency: "USD", balance: balance,
                        balanceDate: oct(16), typeRaw: type.rawValue, isManual: true)
        ctx.insert(a)
        return a
    }

    private func snap(_ ctx: ModelContext, _ id: String, _ days: ClosedRange<Int>, _ balance: Decimal) {
        for d in days { ctx.insert(AccountBalanceSnapshot(accountId: id, day: oct(d), balance: balance)) }
    }

    private func netWorth(_ ctx: ModelContext, _ values: [Int: Decimal]) {
        for (d, v) in values { ctx.insert(NetWorthSnapshot(day: oct(d), value: v)) }
    }

    private func netWorthByDay(_ ctx: ModelContext) throws -> [Int: Decimal] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<NetWorthSnapshot>())
            .map { (cal.component(.day, from: $0.day), $0.value) })
    }

    private func rows(_ ctx: ModelContext, _ id: String) throws -> [(day: Int, balance: Decimal)] {
        try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
            .filter { $0.accountId == id }
            .map { (cal.component(.day, from: $0.day), $0.balance) }
            .sorted { $0.day < $1.day }
    }

    /// old 10-12…14 = 100, kept 10-14…16 = 100; net worth 1000/day, 1100 on the overlap day.
    private func seedOverlap(_ ctx: ModelContext) -> (old: Account, kept: Account) {
        let old = account(ctx, "manual-old")
        let kept = account(ctx, "manual-kept")
        snap(ctx, "manual-old", 12...14, 100)
        snap(ctx, "manual-kept", 14...16, 100)
        netWorth(ctx, [12: 1000, 13: 1000, 14: 1100, 15: 1000, 16: 1000])
        try? ctx.save()
        return (old, kept)
    }

    func testOverlapDayCorrectedOthersUntouched() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let (old, kept) = seedOverlap(ctx)

        let result = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertEqual(result, AccountMerge.Result(overlapDays: 1, movedRows: 2))
        XCTAssertEqual(try netWorthByDay(ctx), [12: 1000, 13: 1000, 14: 1000, 15: 1000, 16: 1000])
    }

    func testPreExistenceRowsMovedToKept() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let (old, kept) = seedOverlap(ctx)

        _ = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertEqual(try rows(ctx, "manual-kept").map(\.day), [12, 13, 14, 15, 16])
        XCTAssertTrue(try rows(ctx, "manual-old").isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Account>()).allSatisfy { $0.id != "manual-old" })
    }

    func testKeptRowsUntouched() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let old = account(ctx, "manual-old")
        let kept = account(ctx, "manual-kept")
        snap(ctx, "manual-old", 14...14, 999)
        snap(ctx, "manual-kept", 14...14, 100)
        try ctx.save()

        _ = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertEqual(try rows(ctx, "manual-kept").map(\.balance), [100])
    }

    func testOverlapDayDebtRaisesNetWorth() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let old = account(ctx, "manual-old", .loan, -412300)
        let kept = account(ctx, "manual-kept", .loan, -411950)
        snap(ctx, "manual-old", 14...14, -412300)
        snap(ctx, "manual-kept", 14...14, -411950)
        netWorth(ctx, [14: 120000])
        try ctx.save()

        _ = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertEqual(try netWorthByDay(ctx), [14: 532300])
    }

    func testDontMergeLeavesTotals() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let (old, _) = seedOverlap(ctx)

        let result = try AccountMerge.delete(old, mergingInto: nil, in: ctx, calendar: cal)

        XCTAssertNil(result)
        XCTAssertEqual(try netWorthByDay(ctx), [12: 1000, 13: 1000, 14: 1100, 15: 1000, 16: 1000])
        XCTAssertEqual(try rows(ctx, "manual-old").count, 3)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Account>()).allSatisfy { $0.id != "manual-old" })
    }

    func testOldWithoutSnapshotsJustDeletes() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let old = account(ctx, "manual-old")
        let kept = account(ctx, "manual-kept")
        snap(ctx, "manual-kept", 14...16, 100)
        netWorth(ctx, [14: 1000])
        try ctx.save()

        let result = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertEqual(result, AccountMerge.Result(overlapDays: 0, movedRows: 0))
        XCTAssertEqual(try netWorthByDay(ctx), [14: 1000])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).map(\.id), ["manual-kept"])
    }

    func testOverlapWithoutNetWorthRowCreatesNone() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let old = account(ctx, "manual-old")
        let kept = account(ctx, "manual-kept")
        snap(ctx, "manual-old", 14...14, 100)
        snap(ctx, "manual-kept", 14...14, 100)
        try ctx.save()

        _ = try AccountMerge.delete(old, mergingInto: kept, in: ctx, calendar: cal)

        XCTAssertTrue(try rows(ctx, "manual-old").isEmpty)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NetWorthSnapshot>()).count, 0)
    }
}
