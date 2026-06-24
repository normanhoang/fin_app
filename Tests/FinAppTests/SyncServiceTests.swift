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

        SyncService.sync(accounts: [dto], into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 2)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).first?.transactions.count, 2)
    }

    func testReSyncIsIdempotent() throws {
        let ctx = makeContext()
        let dto = account(txns: [tx(id: "t1", amount: "-10.00")])

        SyncService.sync(accounts: [dto], into: ctx)
        SyncService.sync(accounts: [dto], into: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 1)
    }

    func testPendingBecomesPostedUpdatesInPlace() throws {
        let ctx = makeContext()
        SyncService.sync(accounts: [account(txns: [tx(id: "t1", amount: "-9.99", pending: true)])], into: ctx)
        // Same transaction id resyncs, now posted with finalized amount.
        SyncService.sync(accounts: [account(txns: [tx(id: "t1", amount: "-10.50", pending: false)])], into: ctx)

        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txns.count, 1)
        XCTAssertEqual(txns.first?.pending, false)
        XCTAssertEqual(txns.first?.amount, Decimal(string: "-10.50"))
    }

    func testUpdatesAccountBalance() throws {
        let ctx = makeContext()
        SyncService.sync(accounts: [account(balance: "100.00", txns: [])], into: ctx)
        SyncService.sync(accounts: [account(balance: "250.00", txns: [])], into: ctx)

        let accts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accts.count, 1)
        XCTAssertEqual(accts.first?.balance, Decimal(string: "250.00"))
    }
}
