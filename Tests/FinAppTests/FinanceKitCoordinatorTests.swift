// Tests/FinAppTests/FinanceKitCoordinatorTests.swift
import XCTest
import SwiftData
@testable import FinApp

final class FakeFinanceKitSource: FinanceKitSource, @unchecked Sendable {
    var available = true
    var status: FKAuthorization = .authorized
    var requestResult: FKAuthorization = .authorized
    var result: Result<[FKAccount], Error> = .success([])
    var fetchCount = 0
    var lastSince: Date?
    func isAvailable() -> Bool { available }
    func authorizationStatus() async throws -> FKAuthorization { status }
    func requestAuthorization() async throws -> FKAuthorization { status = requestResult; return requestResult }
    func fetch(since: Date) async throws -> [FKAccount] { fetchCount += 1; lastSince = since; return try result.get() }
}

@MainActor
final class FinanceKitCoordinatorTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!
    private var source: FakeFinanceKitSource!
    private var clock = Date(timeIntervalSince1970: 1_760_000_000)
    private let cardID = UUID()

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "financeKitLastImportDate")
        UserDefaults.standard.removeObject(forKey: "financeKitMergeDeclined")
        container = AppSchema.makeInMemoryContainer()
        ctx = container.mainContext
        source = FakeFinanceKitSource()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "financeKitLastImportDate")
        UserDefaults.standard.removeObject(forKey: "financeKitMergeDeclined")
    }

    private func make() -> FinanceKitCoordinator {
        FinanceKitCoordinator(source: source, context: ctx, now: { [unowned self] in clock })
    }

    private func card(_ amounts: [String]) -> FKAccount {
        FKAccount(id: cardID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
                  isLiability: true, balance: -10, availableBalance: nil, balanceDate: clock,
                  transactions: amounts.enumerated().map { i, a in
                      FKTransaction(id: UUID(), posted: clock.addingTimeInterval(Double(-i) * 86_400),
                                    amount: Decimal(string: a)!, detail: "FK", payee: nil, status: .booked)
                  })
    }

    func testFirstImportLooksBack120DaysThenOverlap() async {
        let c = make()
        await c.importNow()
        XCTAssertEqual(source.lastSince, Calendar.current.date(byAdding: .day, value: -120, to: clock))
        XCTAssertEqual(c.lastImportDate, clock)

        clock = clock.addingTimeInterval(10 * 86_400)
        await c.importNow()
        XCTAssertEqual(source.lastSince, Calendar.current.date(byAdding: .day, value: -15, to: clock))
    }

    func testImportIfStaleDebounces() async {
        let c = make()
        await c.importIfStale()
        clock = clock.addingTimeInterval(60)
        await c.importIfStale()
        XCTAssertEqual(source.fetchCount, 1)
        clock = clock.addingTimeInterval(300)
        await c.importIfStale()
        XCTAssertEqual(source.fetchCount, 2)
    }

    func testImportSkippedWhenNotAuthorized() async {
        source.status = .denied
        let c = make()
        await c.refreshAuthorization()
        await c.importIfStale()
        XCTAssertEqual(c.authorization, .denied)
        XCTAssertEqual(source.fetchCount, 0)
    }

    func testFetchErrorSurfacesAndChangesNothing() async throws {
        let simplefin = Account(id: "simplefin-account:x", org: "Bank", name: "Checking",
                                currency: "USD", balance: 5, balanceDate: clock)
        ctx.insert(simplefin)
        try ctx.save()
        source.result = .failure(URLError(.notConnectedToInternet))
        let c = make()

        await c.importNow()

        XCTAssertNotNil(c.errorMessage)
        XCTAssertNil(c.lastImportDate)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).map(\.id), ["simplefin-account:x"])
    }

    func testConnectRequestsAuthorizationThenImports() async throws {
        source.status = .notDetermined
        source.result = .success([card(["-1"])])
        let c = make()
        await c.connect()
        XCTAssertEqual(c.authorization, .authorized)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
    }

    private func seedSimplefinOverlap() throws -> Account {
        let sf = Account(id: "simplefin-account:card", org: "Apple", name: "Apple Card (SF)",
                         currency: "USD", balance: -10, balanceDate: clock)
        sf.providerID = "card"
        ctx.insert(sf)
        for (i, a) in ["-1", "-2", "-3"].enumerated() {
            ctx.insert(Transaction(id: "sf\(i)", posted: clock.addingTimeInterval(Double(-i) * 86_400),
                                   amount: Decimal(string: a)!, detail: "SF", account: sf))
        }
        try ctx.save()
        return sf
    }

    func testOverlapProposesMergeAndConfirmMerges() async throws {
        let sf = try seedSimplefinOverlap()
        source.result = .success([card(["-1", "-2", "-3"])])
        let c = make()

        await c.importNow()

        let proposal = try XCTUnwrap(c.pendingMerge)
        XCTAssertEqual(proposal.simplefinAccountID, "simplefin-account:card")
        c.confirmMerge()
        XCTAssertNil(c.pendingMerge)
        XCTAssertEqual(c.lastMergeResult, .init(merged: 3, removed: 0))
        XCTAssertEqual(sf.source, .financeKit)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
    }

    func testDeclinedMergeIsNotReproposed() async throws {
        _ = try seedSimplefinOverlap()
        source.result = .success([card(["-1", "-2", "-3"])])
        let c = make()
        await c.importNow()
        c.declineMerge()
        XCTAssertNil(c.pendingMerge)

        await c.importNow()
        XCTAssertNil(c.pendingMerge)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 2)
    }

    func testUnavailableSourceReportsUnavailable() {
        source.available = false
        XCTAssertFalse(make().isAvailable)
        XCTAssertFalse(FinanceKitCoordinator(source: UnavailableFinanceKitSource(), context: ctx).isAvailable)
    }
}
