#if DEBUG
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class OrphanRepairTests: XCTestCase {
    private func oct(_ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d))!
    }

    private func account(_ ctx: ModelContext, _ id: String) {
        ctx.insert(Account(id: id, org: "Manual", name: id, currency: "USD", balance: 100,
                           balanceDate: oct(16), isManual: true))
    }

    private func snap(_ ctx: ModelContext, _ id: String, _ days: ClosedRange<Int>, _ balance: Decimal) {
        for d in days { ctx.insert(AccountBalanceSnapshot(accountId: id, day: oct(d), balance: balance)) }
    }

    /// Orphan "manual-gone" 10-12…14 = 100 (account already deleted), kept 10-14…16;
    /// net worth 1100 on the overlap day.
    private func seed(_ ctx: ModelContext) {
        account(ctx, "manual-kept")
        account(ctx, "other")
        snap(ctx, "manual-gone", 12...14, 100)
        snap(ctx, "manual-kept", 14...16, 100)
        snap(ctx, "other", 12...16, 900)
        for (d, v) in [12: 1000, 13: 1000, 14: 1100, 15: 1000, 16: 1000] as [Int: Decimal] {
            ctx.insert(NetWorthSnapshot(day: oct(d), value: v))
        }
        try? ctx.save()
    }

    func testListsOrphans() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        seed(ctx)

        XCTAssertEqual(try OrphanRepair.orphans(in: ctx),
                       [OrphanRepair.Orphan(id: "manual-gone", rows: 3, first: oct(12), last: oct(14))])
        XCTAssertTrue(OrphanRepair.run("list", in: ctx).contains("manual-gone"))
    }

    func testRepairMergesOrphanIntoKept() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        seed(ctx)

        let log = OrphanRepair.run("manual-gone=>manual-kept", in: ctx)

        XCTAssertEqual(log, "merged manual-gone → manual-kept: 1 overlap days, 0 skipped, 2 rows moved")
        let total14 = try ctx.fetch(FetchDescriptor<NetWorthSnapshot>())
            .first { Calendar.current.isDate($0.day, inSameDayAs: oct(14)) }?.value
        XCTAssertEqual(total14, 1000)
        XCTAssertEqual(try OrphanRepair.orphans(in: ctx), [])
    }

    /// SimpleFin ids contain colons (`simplefin-account:43:https://…`).
    func testRepairAcceptsIDsWithColons() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let gone = "simplefin-account:43:https://bridge/ACT-1"
        account(ctx, "manual-kept")
        snap(ctx, gone, 13...14, 100)
        snap(ctx, "manual-kept", 14...14, 100)
        try ctx.save()

        let log = OrphanRepair.run("\(gone)=>manual-kept", in: ctx)

        XCTAssertTrue(log.hasPrefix("merged \(gone) → manual-kept"), log)
    }

    func testRepairRefusesLiveOldOrMissingKept() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        seed(ctx)

        let live = OrphanRepair.run("manual-kept=>manual-kept", in: ctx)
        let missing = OrphanRepair.run("manual-gone=>manual-nope", in: ctx)

        XCTAssertTrue(live.hasPrefix("error"), live)
        XCTAssertTrue(missing.hasPrefix("error"), missing)
        XCTAssertEqual(try OrphanRepair.orphans(in: ctx).first?.rows, 3)
    }
}
#endif
