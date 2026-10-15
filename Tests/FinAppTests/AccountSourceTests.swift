import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class AccountSourceTests: XCTestCase {
    func testInitDerivesSourceFromIsManual() {
        let synced = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        let manual = Account(id: "m", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date(), isManual: true)
        XCTAssertEqual(synced.source, .simplefin)
        XCTAssertEqual(manual.source, .manual)
        XCTAssertNil(synced.supersededProviderID)
    }

    func testMigrateManualTagsExistingManualRows() throws {
        let container = AppSchema.makeInMemoryContainer() // must stay alive while its context is used
        let ctx = container.mainContext
        let manual = Account(id: "m", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date(), isManual: true)
        manual.sourceRaw = AccountSource.simplefin.rawValue // simulate a pre-migration row
        let synced = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        ctx.insert(manual); ctx.insert(synced)
        try ctx.save()

        AccountSource.migrateManual(in: ctx)

        XCTAssertEqual(manual.source, .manual)
        XCTAssertEqual(synced.source, .simplefin)
    }

    func testUnknownRawFallsBackToSimplefin() {
        let a = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        a.sourceRaw = "bogus"
        XCTAssertEqual(a.source, .simplefin)
    }
}
