import XCTest
import SwiftData
@testable import FinApp

final class AccountTypeTests: XCTestCase {
    func testSignedBalanceUsesTypeNotTypedSign() {
        XCTAssertEqual(AccountType.cash.signedBalance(from: Decimal(string: "1500")!),
                       Decimal(string: "1500"))
        XCTAssertEqual(AccountType.property.signedBalance(from: Decimal(string: "250000")!),
                       Decimal(string: "250000"))
        XCTAssertEqual(AccountType.creditCard.signedBalance(from: Decimal(string: "1500")!),
                       Decimal(string: "-1500"))
        XCTAssertEqual(AccountType.loan.signedBalance(from: Decimal(string: "8000")!),
                       Decimal(string: "-8000"))
    }

    func testSignedBalanceStripsATypedMinus() {
        XCTAssertEqual(AccountType.cash.signedBalance(from: Decimal(string: "-1500")!),
                       Decimal(string: "1500"))
        XCTAssertEqual(AccountType.creditCard.signedBalance(from: Decimal(string: "-1500")!),
                       Decimal(string: "-1500"))
    }

    func testSelectableTypesOmitOther() {
        XCTAssertFalse(AccountType.selectable.contains(.other))
        XCTAssertEqual(AccountType.selectable, [.cash, .investment, .property, .creditCard, .loan])
    }

    @MainActor
    func testMigrateOtherRewritesToCash() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        ctx.insert(Account(
            id: "manual-other",
            org: "Manual",
            name: "Misc",
            currency: "USD",
            balance: Decimal(string: "40")!,
            balanceDate: Date(),
            typeRaw: AccountType.other.rawValue,
            isManual: true
        ))
        ctx.insert(Account(
            id: "loan-1",
            org: "Manual",
            name: "Car",
            currency: "USD",
            balance: Decimal(string: "-200")!,
            balanceDate: Date(),
            typeRaw: AccountType.loan.rawValue,
            isManual: true
        ))
        try ctx.save()

        AccountType.migrateOther(in: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.first { $0.id == "manual-other" }?.accountType, .cash)
        XCTAssertEqual(accounts.first { $0.id == "loan-1" }?.accountType, .loan)
    }
}
