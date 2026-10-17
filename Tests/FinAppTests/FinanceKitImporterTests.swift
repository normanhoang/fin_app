import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class FinanceKitImporterTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!
    private let cardID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let day = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
        ctx = container.mainContext
    }

    private func txn(_ n: Int, _ amount: String, status: FKTransaction.Status = .booked) -> FKTransaction {
        FKTransaction(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                      posted: day, amount: Decimal(string: amount)!, detail: "DESC \(n)",
                      payee: "Merchant \(n)", status: status)
    }

    private func card(balance: String = "-120.00", _ txns: [FKTransaction]) -> FKAccount {
        FKAccount(id: cardID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
                  isLiability: true, balance: Decimal(string: balance)!, availableBalance: 4880,
                  balanceDate: day, transactions: txns)
    }

    private func accounts() throws -> [Account] { try ctx.fetch(FetchDescriptor<Account>()) }
    private func txns() throws -> [Transaction] { try ctx.fetch(FetchDescriptor<Transaction>()) }

    func testSignedMapping() {
        XCTAssertEqual(FinanceKitMapping.signed(12, isDebit: true), -12)
        XCTAssertEqual(FinanceKitMapping.signed(12, isDebit: false), 12)
        XCTAssertEqual(FinanceKitMapping.signed(-12, isDebit: true), -12, "magnitude is used")
    }

    /// Device-observed: balances use the accounting indicator — Apple Cash holding
    /// money comes back `.debit`, an Apple Card amount owed comes back `.credit`.
    func testBalanceMappingFollowsAccountingIndicator() {
        XCTAssertEqual(FinanceKitMapping.balance(50, isDebit: true, isLiability: false), 50,
                       "Apple Cash balance (debit) is money held → positive")
        XCTAssertEqual(FinanceKitMapping.balance(50, isDebit: false, isLiability: false), 50,
                       "asset balances can't be overdrawn → positive either way")
        XCTAssertEqual(FinanceKitMapping.balance(300, isDebit: false, isLiability: true), -300,
                       "Apple Card amount owed (credit) → negative")
        XCTAssertEqual(FinanceKitMapping.balance(20, isDebit: true, isLiability: true), 20,
                       "overpaid card (debit) → positive")
    }

    func testFirstImportInsertsAccountAndTransactions() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00"), txn(2, "25.00")])], into: ctx)

        let a = try XCTUnwrap(accounts().first)
        XCTAssertEqual(a.id, "financekit-\(cardID.uuidString)")
        XCTAssertEqual(a.source, .financeKit)
        XCTAssertEqual(a.providerID, cardID.uuidString)
        XCTAssertEqual(a.accountType, .creditCard)
        XCTAssertEqual(a.org, "Apple")
        XCTAssertEqual(a.balance, Decimal(string: "-120.00"))
        XCTAssertEqual(a.availableBalance, 4880)
        XCTAssertNotNil(a.lastSyncedAt)
        XCTAssertEqual(try txns().count, 2)
        XCTAssertEqual(Set(try txns().map(\.amount)), [Decimal(string: "-10.00")!, 25])
        XCTAssertEqual(try txns().first?.account?.id, a.id)
    }

    func testAssetAccountTypedCash() throws {
        let cash = FKAccount(id: UUID(), institutionName: "Apple", displayName: "Apple Cash", currency: "USD",
                             isLiability: false, balance: 40, availableBalance: nil, balanceDate: day, transactions: [])
        try FinanceKitImporter.stage([cash], into: ctx)
        XCTAssertEqual(try accounts().first?.accountType, .cash)
    }

    func testReimportIsIdempotentAndUpdatesInPlace() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .pending)])], into: ctx)
        let first = try XCTUnwrap(txns().first)

        try FinanceKitImporter.stage([card(balance: "-130.00", [txn(1, "-10.00", status: .booked)])], into: ctx)

        XCTAssertEqual(try accounts().count, 1)
        XCTAssertEqual(try txns().count, 1)
        XCTAssertTrue(try txns().first === first)
        XCTAssertFalse(first.pending)
        XCTAssertEqual(try accounts().first?.balance, Decimal(string: "-130.00"))
    }

    func testRejectedDeletesAndMemoSkipped() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .pending)])], into: ctx)
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .rejected), txn(2, "-1.00", status: .memo)])], into: ctx)
        XCTAssertTrue(try txns().isEmpty)
    }

    func testUserEditsSurviveReimport() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)
        let a = try XCTUnwrap(accounts().first)
        a.customName = "Card"; a.customSortIndex = 3; a.accountType = .loan
        let t = try XCTUnwrap(txns().first)
        t.note = "lunch"; t.categorizedByUser = true
        let cat = FinApp.Category(name: "Food", colorHex: "#FF0000", systemIcon: "fork.knife")
        ctx.insert(cat); t.category = cat

        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)

        XCTAssertEqual(a.displayName, "Card")
        XCTAssertEqual(a.customSortIndex, 3)
        XCTAssertEqual(a.accountType, .loan)
        XCTAssertEqual(t.note, "lunch")
        XCTAssertTrue(t.category === cat)
    }

    func testPruneRemovesOnlyMissingFinanceKitAccounts() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)
        let simplefin = Account(id: "simplefin-account:x", org: "Bank", name: "Checking", currency: "USD",
                                balance: 1, balanceDate: day)
        let manual = Account(id: "manual-1", org: "Manual", name: "Cash", currency: "USD",
                             balance: 1, balanceDate: day, isManual: true)
        ctx.insert(simplefin); ctx.insert(manual)

        let other = FKAccount(id: UUID(), institutionName: "Apple", displayName: "Apple Cash", currency: "USD",
                              isLiability: false, balance: 5, availableBalance: nil, balanceDate: day,
                              transactions: [])
        try FinanceKitImporter.stage([other], into: ctx)

        XCTAssertEqual(Set(try accounts().map(\.id)),
                       ["simplefin-account:x", "manual-1", FinanceKitImporter.accountStorageID(other.id)])
        XCTAssertTrue(try txns().isEmpty, "cascade deleted")
    }

    func testEmptyFetchDoesNotPrune() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)
        try FinanceKitImporter.stage([], into: ctx)
        XCTAssertEqual(try accounts().count, 1)
        XCTAssertEqual(try txns().count, 1)
    }

    func testMergedAccountIsNeverPruned() throws {
        let other = FKAccount(id: UUID(), institutionName: "Apple", displayName: "Apple Cash", currency: "USD",
                              isLiability: false, balance: 5, availableBalance: nil, balanceDate: day,
                              transactions: [])
        try FinanceKitImporter.stage([card([txn(1, "-10.00")]), other], into: ctx)
        let a = try XCTUnwrap(accounts().first { $0.id == FinanceKitImporter.accountStorageID(cardID) })
        a.supersededProviderID = "simplefin-account:old"

        try FinanceKitImporter.stage([other], into: ctx)

        XCTAssertEqual(try accounts().count, 2)
        XCTAssertEqual(try txns().count, 1)
    }
}
