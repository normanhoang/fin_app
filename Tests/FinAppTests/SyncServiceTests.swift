import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class SyncServiceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = await AppSchema.makeInMemoryContainer()
    }

    private func makeContext() -> ModelContext {
        container.mainContext
    }

    private func account(
        id: String = "a1",
        balance: String = "100.00",
        txns: [TransactionDTO]
    ) -> AccountDTO {
        AccountDTO(
            id: id, org: "Bank", name: "Checking", currency: "USD",
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

    func testBankOfAmericaCheckingSwapsBalanceAndAvailable() throws {
        let ctx = makeContext()
        let dto = AccountDTO(
            id: "boa", org: "Bank of America", name: "Bank of America Checking", currency: "USD",
            balance: Decimal(string: "10.00")!, availableBalance: Decimal(string: "1234.00")!,
            balanceDate: Date(), transactions: []
        )
        try SyncService.sync(accounts: [dto], into: ctx)
        try SyncService.sync(accounts: [dto], into: ctx) // idempotent

        let acct = try ctx.fetch(FetchDescriptor<Account>()).first
        XCTAssertEqual(acct?.balance, Decimal(string: "1234.00"), "Balance should show the available value")
        XCTAssertEqual(acct?.availableBalance, Decimal(string: "10.00"))
    }

    func testOtherAccountsAreNotSwapped() throws {
        let ctx = makeContext()
        let dto = AccountDTO(
            id: "c1", org: "Chase", name: "Checking", currency: "USD",
            balance: Decimal(string: "10.00")!, availableBalance: Decimal(string: "1234.00")!,
            balanceDate: Date(), transactions: []
        )
        try SyncService.sync(accounts: [dto], into: ctx)
        let acct = try ctx.fetch(FetchDescriptor<Account>()).first
        XCTAssertEqual(acct?.balance, Decimal(string: "10.00"))
    }

    func testReSyncIsIdempotent() throws {
        let ctx = makeContext()
        let dto = account(txns: [tx(id: "t1", amount: "-10.00")])

        try SyncService.sync(accounts: [dto], into: ctx)
        try SyncService.sync(accounts: [dto], into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 1)
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

    func testPruneRemovesSyncedAccountMissingFromResponse() throws {
        let ctx = makeContext()
        try SyncService.sync(accounts: [account(id: "a1", txns: [tx(id: "t1", amount: "-5.00")]),
                                    account(id: "a2", txns: [tx(id: "t2", amount: "-6.00")])],
                         into: ctx)

        try SyncService.sync(accounts: [account(id: "a1", txns: [])], pruneMissing: true, into: ctx)

        let accts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accts.map(\.id), ["a1"])
        // a2's transactions cascade away; a1's remain.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).map(\.id), ["t1"])
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

        let ids = try ctx.fetch(FetchDescriptor<Account>()).map(\.id).sorted()
        XCTAssertEqual(ids, ["a1", "manual-1"])
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
