import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class SchemaTests: XCTestCase {
    func testContainerBuildsAndInsertsAccount() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext

        let account = Account(
            id: "acct-1",
            org: "Test Bank",
            name: "Checking",
            currency: "USD",
            balance: Decimal(string: "1234.56")!,
            balanceDate: Date()
        )
        ctx.insert(account)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.balance, Decimal(string: "1234.56"))
    }
}
