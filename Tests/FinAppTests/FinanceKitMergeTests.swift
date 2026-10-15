// Tests/FinAppTests/FinanceKitMergeTests.swift
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class FinanceKitMergeTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!
    private let cal = Calendar(identifier: .gregorian)
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        container = AppSchema.makeInMemoryContainer()
        ctx = container.mainContext
    }

    private func d(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: base)! }

    /// SimpleFin-sourced account that has been through a scoped sync (providerID set).
    private func simplefin(_ txns: [(Int, String)]) -> Account { simplefin("simplefin-account:old", txns) }

    private func simplefin(_ id: String, _ txns: [(Int, String)]) -> Account {
        let a = Account(id: id, org: "Apple", name: "Apple Card (SF)", currency: "USD",
                        balance: -100, balanceDate: base, typeRaw: AccountType.creditCard.rawValue)
        a.providerID = "raw-\(id)"
        ctx.insert(a)
        for (i, (day, amount)) in txns.enumerated() {
            let t = Transaction(id: "\(id)-t\(i)", posted: d(day), amount: Decimal(string: amount)!,
                                detail: "SF \(i)", account: a)
            t.providerID = "sf\(i)"
            ctx.insert(t)
        }
        return a
    }

    /// FinanceKit account built via the real importer.
    private func financeKit(_ txns: [(Int, String)]) throws -> Account {
        let accountID = UUID()
        let dtos = txns.enumerated().map { i, t in
            FKTransaction(id: UUID(), posted: d(t.0), amount: Decimal(string: t.1)!,
                          detail: "FK \(i)", payee: "Merchant", status: .booked)
        }
        try FinanceKitImporter.stage([FKAccount(
            id: accountID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
            isLiability: true, balance: -100, availableBalance: nil, balanceDate: base, transactions: dtos
        )], into: ctx)
        return try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first { $0.id == FinanceKitImporter.accountStorageID(accountID) })
    }

    func testPairUsesEachOnceAndPrefersClosestDate() throws {
        let old = simplefin([(0, "-9.99"), (5, "-9.99"), (20, "-50.00")])
        let fk = try financeKit([(1, "-9.99"), (5, "-9.99"), (40, "-50.00")])

        let pairs = FinanceKitMerge.pair(old.transactions, fk.transactions, calendar: cal)

        XCTAssertEqual(pairs.count, 2, "-50 is 20 days apart → unmatched")
        let byOldDay = Dictionary(uniqueKeysWithValues: pairs.map { (cal.dateComponents([.day], from: base, to: $0.old.posted).day!, cal.dateComponents([.day], from: base, to: $0.new.posted).day!) })
        XCTAssertEqual(byOldDay, [0: 1, 5: 5])
    }

    func testCandidateRequiresThreeMatches() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let two = simplefin("simplefin-account:two", [(0, "-1"), (1, "-2")])
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, two]))

        let three = simplefin("simplefin-account:three", [(0, "-1"), (1, "-2"), (3, "-3")])
        XCTAssertTrue(FinanceKitMerge.candidate(for: fk, among: [fk, two, three]) === three)
    }

    func testNoCandidateWhenAmbiguous() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let a = simplefin("simplefin-account:a", [(0, "-1"), (1, "-2"), (2, "-3")])
        let b = simplefin("simplefin-account:b", [(0, "-1"), (1, "-2"), (2, "-3")])
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, a, b]))
    }

    func testLegacyAndNonSimplefinRowsAreNeverCandidates() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let legacy = simplefin("legacy-raw-id", [(0, "-1"), (1, "-2"), (2, "-3")])
        legacy.providerID = nil
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, legacy]))

        let manual = simplefin("manual-x", [(0, "-1"), (1, "-2"), (2, "-3")])
        manual.source = .manual
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, manual]))
    }

    func testMergeRekeysPreservesEditsAndPrunesDuplicates() throws {
        // old: 3 matching, 1 pre-range (day -30), 1 in-range unmatched, 1 in-range unmatched but edited
        let old = simplefin([(0, "-1"), (1, "-2"), (2, "-3"), (-30, "-7"), (1, "-8"), (2, "-9")])
        old.customName = "My Card"
        let sorted = old.transactions.sorted { $0.id < $1.id }
        sorted[0].note = "kept note"            // matched
        sorted[5].categorizedByUser = true       // in-range unmatched, edited → kept
        ctx.insert(AccountBalanceSnapshot(accountId: old.id, day: d(-1), balance: -90))
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3"), (3, "-4")])
        let fkID = fk.id
        ctx.insert(AccountBalanceSnapshot(accountId: fkID, day: d(0), balance: -100))
        let oldID = old.id
        try ctx.save()

        let result = try FinanceKitMerge.merge(fk, into: old, in: ctx)

        XCTAssertEqual(result, .init(merged: 3, removed: 1))
        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1)
        let merged = try XCTUnwrap(accounts.first)
        XCTAssertTrue(merged === old, "same row survives")
        XCTAssertEqual(merged.id, fkID)
        XCTAssertEqual(merged.source, .financeKit)
        XCTAssertEqual(merged.supersededProviderID, oldID)
        XCTAssertEqual(merged.displayName, "My Card")
        XCTAssertNil(merged.providerScope)

        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        // 3 matched (rekeyed) + 1 FK-only + 1 pre-range + 1 edited = 6; "-8" removed
        XCTAssertEqual(txns.count, 6)
        XCTAssertFalse(txns.contains { $0.amount == -8 })
        XCTAssertTrue(txns.allSatisfy { $0.account === merged })
        let noted = try XCTUnwrap(txns.first { $0.note == "kept note" })
        XCTAssertTrue(noted.id.hasPrefix(fkID), "matched txn rekeyed to FinanceKit id")
        XCTAssertEqual(noted.detail, "FK 0", "bank fields come from FinanceKit")

        let snaps = try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        XCTAssertEqual(snaps.map(\.accountId), [fkID])
        XCTAssertEqual(snaps.first?.balance, -90, "old history kept, FK's temp snapshot dropped")
    }
}
