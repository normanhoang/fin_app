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

    /// Accounts-list row subtitle: only manual accounts get a source tag.
    func testListMetaTagsOnlyManualAccounts() {
        let wallet = Account(id: "financekit-1", org: "Apple", name: "Apple Cash", currency: "USD",
                             balance: 5, balanceDate: Date(), typeRaw: AccountType.cash.rawValue)
        wallet.source = .financeKit
        XCTAssertEqual(wallet.listMeta, AccountType.cash.displayName)

        let synced = Account(id: "s", org: "Chase", name: "Checking", currency: "USD",
                             balance: 5, balanceDate: Date(), typeRaw: AccountType.cash.rawValue)
        XCTAssertEqual(synced.listMeta, AccountType.cash.displayName)

        let manual = Account(id: "manual-1", org: "Me", name: "House", currency: "USD", balance: 5,
                             balanceDate: Date(), typeRaw: AccountType.cash.rawValue, isManual: true)
        manual.source = .manual
        XCTAssertEqual(manual.listMeta, "\(AccountType.cash.displayName) · manual")
    }

    /// "auto" only while the schedule actually drives the balance (type is Loan).
    func testListMetaAutoOnlyForScheduledLoan() throws {
        let container = AppSchema.makeInMemoryContainer()
        let loan = Account(id: "manual-2", org: "Me", name: "Mortgage", currency: "USD", balance: -5,
                           balanceDate: Date(), typeRaw: AccountType.loan.rawValue, isManual: true)
        container.mainContext.insert(loan)
        var draft = LoanDraft()
        draft.balanceText = "1000"; draft.rateText = "6"; draft.totalText = "100"
        loan.loanSchedule = LoanSchedule(inputs: try draft.validate().get())
        XCTAssertEqual(loan.listMeta, "\(AccountType.loan.displayName) · auto")

        loan.accountType = .creditCard
        XCTAssertEqual(loan.listMeta, "\(AccountType.creditCard.displayName) · manual")
    }

    /// The account-detail delete note names the service that re-adds the account.
    func testDeleteNoteMatchesSource() {
        XCTAssertNil(AccountSource.manual.deleteNote)
        XCTAssertTrue(AccountSource.simplefin.deleteNote?.contains("SimpleFin") == true)
        let wallet = AccountSource.financeKit.deleteNote
        XCTAssertTrue(wallet?.contains("Apple Wallet") == true)
        XCTAssertFalse(wallet?.contains("SimpleFin") == true, "Wallet accounts must not mention SimpleFin")
    }
}
