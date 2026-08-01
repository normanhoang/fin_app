import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class SyncServiceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
    }

    private func makeContext() -> ModelContext {
        container.mainContext
    }

    private func account(
        id: String = "a1",
        providerScope: String = "bank.example",
        balance: String = "100.00",
        txns: [TransactionDTO]
    ) -> AccountDTO {
        AccountDTO(
            id: id, providerScope: providerScope, org: "Bank", name: "Checking", currency: "USD",
            balance: Decimal(string: balance)!, availableBalance: nil,
            balanceDate: Date(timeIntervalSince1970: 1_700_000_000),
            transactions: txns
        )
    }

    private func tx(
        id: String, amount: String, detail: String = "X",
        pending: Bool = false
    ) -> TransactionDTO {
        TransactionDTO(
            id: id, posted: Date(timeIntervalSince1970: 1_699_000_000),
            amount: Decimal(string: amount)!, detail: detail,
            payee: nil, memo: nil, pending: pending
        )
    }

    func testInsertsAccountsAndTransactions() throws {
        let ctx = makeContext()
        let dto = account(txns: [tx(id: "t1", amount: "-10.00"), tx(id: "t2", amount: "-20.00")])

        try SyncService.sync(accounts: [dto], into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 2)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).first?.transactions.count, 2)
    }

    func testSyncStampsLastSyncedAt() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [])], into: ctx)
        let acct = try ctx.fetch(FetchDescriptor<Account>()).first
        XCTAssertNotNil(acct?.lastSyncedAt)
        // Re-sync moves the stamp on the existing row too.
        let before = acct?.lastSyncedAt
        try SyncService.sync(accounts: [account(txns: [])], into: ctx)
        XCTAssertNotNil(acct?.lastSyncedAt)
        XCTAssertGreaterThanOrEqual(acct!.lastSyncedAt!, before!)
    }

    func testBalanceAndAvailableStoredAsReported() throws {
        let ctx = makeContext()
        let dto = AccountDTO(
            id: "c1", providerScope: "chase.example", org: "Chase", name: "Checking", currency: "USD",
            balance: Decimal(string: "10.00")!, availableBalance: Decimal(string: "1234.00")!,
            balanceDate: Date(), transactions: []
        )
        try SyncService.sync(accounts: [dto], into: ctx)
        let acct = try ctx.fetch(FetchDescriptor<Account>()).first
        XCTAssertEqual(acct?.balance, Decimal(string: "10.00"))
        XCTAssertEqual(acct?.availableBalance, Decimal(string: "1234.00"))
    }

    func testReSyncIsIdempotent() throws {
        let ctx = makeContext()
        let dto = account(txns: [tx(id: "t1", amount: "-10.00")])

        try SyncService.sync(accounts: [dto], into: ctx)
        try SyncService.sync(accounts: [dto], into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    func testScopesRepeatedProviderIDsWithoutMergingRows() throws {
        let ctx = makeContext()
        let first = account(id: "shared-account", providerScope: "first.example",
                            txns: [tx(id: "shared-transaction", amount: "-10.00")])
        let second = account(id: "shared-account", providerScope: "second.example",
                             txns: [tx(id: "shared-transaction", amount: "-20.00")])

        try SyncService.sync(accounts: [first, second], into: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        let transactions = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.compactMap(\.providerScope)), ["first.example", "second.example"])
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(Set(transactions.map(\.amount)), [Decimal(-10), Decimal(-20)])
        XCTAssertEqual(Set(transactions.compactMap { $0.account?.providerScope }),
                       ["first.example", "second.example"])
    }

    func testLegacyRowsMigrateInPlaceAndPreserveUserDataAndSnapshots() throws {
        let ctx = makeContext()
        let category = Category(name: "Dining", colorHex: "#fff", systemIcon: "fork.knife")
        let legacyAccount = Account(id: "a1", org: "Bank", name: "Checking", currency: "USD",
                                    balance: 10, balanceDate: Date())
        legacyAccount.customName = "My checking"
        let legacyTransaction = Transaction(id: "t1", posted: Date(), amount: -5,
                                            detail: "Lunch", note: "With Sam",
                                            categorizedByUser: true, account: legacyAccount,
                                            category: category)
        let snapshot = AccountBalanceSnapshot(accountId: "a1", day: Date(), balance: 10)
        ctx.insert(category)
        ctx.insert(legacyAccount)
        ctx.insert(legacyTransaction)
        ctx.insert(snapshot)
        try ctx.save()

        try SyncService.sync(accounts: [account(id: "a1", providerScope: "bank.example",
                                                txns: [tx(id: "t1", amount: "-6.00")])], into: ctx)

        let migratedAccount = try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first)
        let migratedTransaction = try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first)
        let migratedSnapshot = try XCTUnwrap(ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>()).first)
        XCTAssertTrue(migratedAccount === legacyAccount)
        XCTAssertTrue(migratedTransaction === legacyTransaction)
        XCTAssertEqual(migratedAccount.customName, "My checking")
        XCTAssertEqual(migratedAccount.providerID, "a1")
        XCTAssertEqual(migratedAccount.providerScope, "bank.example")
        XCTAssertEqual(migratedTransaction.note, "With Sam")
        XCTAssertEqual(migratedTransaction.category?.name, "Dining")
        XCTAssertTrue(migratedTransaction.categorizedByUser)
        XCTAssertEqual(migratedTransaction.providerID, "t1")
        XCTAssertEqual(migratedSnapshot.accountId, migratedAccount.id)
        XCTAssertNotEqual(migratedAccount.id, "a1")
    }

    func testScopeChangeRekeysAccountInPlace() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(id: "a1", providerScope: "bank.example",
                                                txns: [tx(id: "t1", amount: "-5.00")])], into: ctx)
        let acct = try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first)
        acct.customName = "My checking"
        let txn = try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first)
        txn.note = "keep me"
        ctx.insert(AccountBalanceSnapshot(accountId: acct.id, day: Date(), balance: 10))
        try ctx.save()

        // The bridge starts reporting sfin-url for the same org, changing the scope.
        try SyncService.sync(accounts: [account(id: "a1", providerScope: "https://sfin.example/bank",
                                                txns: [tx(id: "t1", amount: "-5.00")])],
                             pruneMissing: true, into: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts.first === acct)
        XCTAssertEqual(accounts.first?.customName, "My checking")
        XCTAssertEqual(accounts.first?.providerScope, "https://sfin.example/bank")
        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txns.count, 1)
        XCTAssertEqual(txns.first?.note, "keep me")
        let snapshot = try XCTUnwrap(ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>()).first)
        XCTAssertEqual(snapshot.accountId, accounts.first?.id)
    }

    func testAmbiguousLegacyRawIDMigratesToMatchingOrg() throws {
        let ctx = makeContext()
        let legacy = Account(id: "shared", org: "Chase", name: "Checking", currency: "USD",
                             balance: 10, balanceDate: Date())
        legacy.customName = "My Chase"
        ctx.insert(legacy)
        try ctx.save()

        let amex = AccountDTO(id: "shared", providerScope: "amex.example", org: "Amex",
                              name: "Card", currency: "USD", balance: -50, availableBalance: nil,
                              balanceDate: Date(), transactions: [])
        let chase = AccountDTO(id: "shared", providerScope: "chase.example", org: "Chase",
                               name: "Checking", currency: "USD", balance: 10, availableBalance: nil,
                               balanceDate: Date(), transactions: [])

        // Amex comes first in the response but must not claim Chase's legacy row.
        try SyncService.sync(accounts: [amex, chase], into: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 2)
        let chaseRow = try XCTUnwrap(accounts.first { $0.providerScope == "chase.example" })
        XCTAssertTrue(chaseRow === legacy)
        XCTAssertEqual(chaseRow.customName, "My Chase")
        XCTAssertNil(accounts.first { $0.providerScope == "amex.example" }?.customName)
    }

    func testUserNoteSurvivesReSync() throws {
        let ctx = makeContext()
        let dto = account(txns: [tx(id: "t1", amount: "-10.00")])
        try SyncService.sync(accounts: [dto], into: ctx)

        let txn = try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first)
        txn.note = "split with roommate"
        try ctx.save()

        try SyncService.sync(accounts: [dto], into: ctx)

        let resynced = try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(resynced.note, "split with roommate")
    }

    func testPendingBecomesPostedUpdatesInPlace() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [tx(id: "t1", amount: "-9.99", pending: true)])], into: ctx)
        // Same transaction id resyncs, now posted with finalized amount.
        try SyncService.sync(accounts: [account(txns: [tx(id: "t1", amount: "-10.50", pending: false)])], into: ctx)

        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txns.count, 1)
        XCTAssertEqual(txns.first?.pending, false)
        XCTAssertEqual(txns.first?.amount, Decimal(string: "-10.50"))
    }

    func testStalePendingTransactionPrunedFromCleanResponse() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [tx(id: "hold", amount: "-200.00", pending: true),
                                                       tx(id: "t1", amount: "-5.00")])], into: ctx)

        // The hold was canceled (or re-posted under a new id): a clean response
        // no longer contains it.
        try SyncService.sync(accounts: [account(txns: [tx(id: "t1", amount: "-5.00")])],
                             pruneMissing: true, into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).map(\.providerID), ["t1"])
    }

    func testStalePendingTransactionKeptWhenResponseNotClean() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [tx(id: "hold", amount: "-200.00", pending: true)])],
                             into: ctx)

        try SyncService.sync(accounts: [account(txns: [])], pruneMissing: false, into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    func testPostedTransactionOutsideWindowNotPruned() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [tx(id: "old", amount: "-5.00")])], into: ctx)

        // Later sync window no longer includes the old posted txn — it must stay.
        try SyncService.sync(accounts: [account(txns: [tx(id: "new", amount: "-7.00")])],
                             pruneMissing: true, into: ctx)

        XCTAssertEqual(Set(try ctx.fetch(FetchDescriptor<Transaction>()).map(\.providerID)),
                       ["old", "new"])
    }

    func testPruneRemovesSyncedAccountMissingFromResponse() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(id: "a1", txns: [tx(id: "t1", amount: "-5.00")]),
                                    account(id: "a2", txns: [tx(id: "t2", amount: "-6.00")])],
                         into: ctx)

        try SyncService.sync(accounts: [account(id: "a1", txns: [])], pruneMissing: true, into: ctx)

        let accts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accts.map(\.providerID), ["a1"])
        // a2's transactions cascade away; a1's remain.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).map(\.providerID), ["t1"])
    }

    func testPruneSkippedWhenNotRequested() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(id: "a1", txns: []), account(id: "a2", txns: [])], into: ctx)

        // e.g. the response carried provider errors — caller passes pruneMissing: false.
        try SyncService.sync(accounts: [account(id: "a1", txns: [])], pruneMissing: false, into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 2)
    }

    func testPruneLeavesManualAccountsAlone() throws {
        let ctx = makeContext()
        ctx.insert(Account(id: "manual-1", org: "", name: "Cash", currency: "USD",
                           balance: 50, availableBalance: nil,
                           balanceDate: Date(), isManual: true))
        try ctx.save()

        try SyncService.sync(accounts: [account(id: "a1", txns: [])], pruneMissing: true, into: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.filter(\.isManual).map(\.id), ["manual-1"])
        XCTAssertEqual(accounts.filter { !$0.isManual }.compactMap(\.providerID), ["a1"])
    }

    func testNewAccountGetsDetectedType() throws {
        let ctx = makeContext()
        let dto = AccountDTO(
            id: "cc1", providerScope: "chase.example", org: "Chase", name: "Chase Sapphire Credit Card", currency: "USD",
            balance: Decimal(string: "-250.00")!, availableBalance: nil,
            balanceDate: Date(), transactions: []
        )
        try SyncService.sync(accounts: [dto], into: ctx)

        let acct = try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(acct.accountType, .creditCard)
    }

    func testUserChosenTypeSurvivesReSync() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(txns: [])], into: ctx)

        let acct = try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first)
        acct.accountType = .investment
        try ctx.save()

        try SyncService.sync(accounts: [account(txns: [])], into: ctx)

        let resynced = try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(resynced.accountType, .investment)
    }

    func testUpdatesAccountBalance() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(balance: "100.00", txns: [])], into: ctx)
        try SyncService.sync(accounts: [account(balance: "250.00", txns: [])], into: ctx)

        let accts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accts.count, 1)
        XCTAssertEqual(accts.first?.balance, Decimal(string: "250.00"))
    }
}
