import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
    }

    func testDisconnectInvalidatesAnInFlightResponse() async throws {
        let container = AppSchema.makeInMemoryContainer()
        let accessURL = URL(string: "https://user:pass@bridge.example/simplefin")!
        var storedURL: URL? = accessURL
        var fetchContinuation: CheckedContinuation<SimpleFinResponse, Error>?
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { storedURL },
            saveAccessURL: { storedURL = $0 },
            deleteAccessURL: { storedURL = nil },
            claim: { _ in accessURL },
            fetch: { _, _ in
                try await withCheckedThrowingContinuation { fetchContinuation = $0 }
            }
        )

        let syncTask = Task { await coordinator.sync() }
        while fetchContinuation == nil { await Task.yield() }
        coordinator.disconnect()
        fetchContinuation?.resume(returning: SimpleFinResponse(
            errors: [],
            accounts: [AccountDTO(
                id: "a1", providerScope: "bank.example", org: "Bank",
                name: "Checking", currency: "USD", balance: 100,
                availableBalance: nil, balanceDate: Date(), transactions: []
            )]
        ))
        await syncTask.value

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertNil(coordinator.lastSyncDate)
        XCTAssertFalse(coordinator.isConnected)
    }

    func testFailedFetchDoesNotStampSuccessAndSurfacesError() async {
        let container = AppSchema.makeInMemoryContainer()
        enum ExpectedFailure: LocalizedError {
            case failed
            var errorDescription: String? { "Expected fetch failure" }
        }
        let accessURL = URL(string: "https://user:pass@bridge.example/simplefin")!
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { accessURL },
            saveAccessURL: { _ in },
            deleteAccessURL: {},
            claim: { _ in accessURL },
            fetch: { _, _ in throw ExpectedFailure.failed }
        )

        await coordinator.sync()

        XCTAssertNil(coordinator.lastSyncDate)
        XCTAssertEqual(coordinator.errorMessage, "Expected fetch failure")
    }

    func testReconnectDuringFetchQueuesSyncForNewestCredential() async throws {
        let container = AppSchema.makeInMemoryContainer()
        let oldURL = URL(string: "https://old:pass@bridge.example/simplefin")!
        let newURL = URL(string: "https://new:pass@bridge.example/simplefin")!
        var storedURL: URL? = oldURL
        var oldFetch: CheckedContinuation<SimpleFinResponse, Error>?
        let newResponse = SimpleFinResponse(errors: [], accounts: [AccountDTO(
            id: "new-account", providerScope: "new.example", org: "New Bank",
            name: "Checking", currency: "USD", balance: 100,
            availableBalance: nil, balanceDate: Date(), transactions: []
        )])
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { storedURL },
            saveAccessURL: { storedURL = $0 },
            deleteAccessURL: { storedURL = nil },
            claim: { _ in newURL },
            fetch: { url, _ in
                if url == oldURL {
                    return try await withCheckedThrowingContinuation { oldFetch = $0 }
                }
                return newResponse
            }
        )

        let oldTask = Task { await coordinator.sync() }
        while oldFetch == nil { await Task.yield() }
        await coordinator.connect(setupToken: "new-token")
        oldFetch?.resume(returning: SimpleFinResponse(errors: [], accounts: []))
        await oldTask.value

        for _ in 0..<100 where (try? container.mainContext.fetch(FetchDescriptor<Account>()))?.isEmpty == true {
            await Task.yield()
        }
        let account = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(account.providerScope, "new.example")
        XCTAssertEqual(storedURL, newURL)
    }

    func testInvalidatedClaimFailureDoesNotPublishAnError() async {
        enum OldClaimFailure: LocalizedError {
            case failed
            var errorDescription: String? { "Old claim failed" }
        }
        let container = AppSchema.makeInMemoryContainer()
        var claimContinuation: CheckedContinuation<URL, Error>?
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { nil },
            saveAccessURL: { _ in },
            deleteAccessURL: {},
            claim: { _ in
                try await withCheckedThrowingContinuation { claimContinuation = $0 }
            },
            fetch: { _, _ in SimpleFinResponse(errors: [], accounts: []) }
        )

        let task = Task { await coordinator.connect(setupToken: "old") }
        while claimContinuation == nil { await Task.yield() }
        coordinator.disconnect()
        claimContinuation?.resume(throwing: OldClaimFailure.failed)
        await task.value

        XCTAssertNil(coordinator.errorMessage)
    }

    func testFetchFailureLeavesUnsavedUserEditsIntact() async throws {
        enum FetchFailure: Error { case failed }
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        // Model the window where a user's new manual account has not autosaved yet.
        ctx.autosaveEnabled = false
        let account = Account(id: "manual-1", org: "", name: "Cash", currency: "USD",
                              balance: 50, balanceDate: Date(), isManual: true)
        ctx.insert(account)

        let accessURL = URL(string: "https://user:pass@bridge.example/simplefin")!
        let coordinator = SyncCoordinator(
            context: ctx,
            loadAccessURL: { accessURL },
            saveAccessURL: { _ in },
            deleteAccessURL: {},
            claim: { _ in accessURL },
            fetch: { _, _ in throw FetchFailure.failed }
        )

        await coordinator.sync()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).map(\.id), ["manual-1"])
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testSyncStartedDuringClaimDoesNotStarveQueuedPostConnectSync() async throws {
        let container = AppSchema.makeInMemoryContainer()
        let oldURL = URL(string: "https://old:pass@bridge.example/simplefin")!
        let newURL = URL(string: "https://new:pass@bridge.example/simplefin")!
        var storedURL: URL? = oldURL
        var claimContinuation: CheckedContinuation<URL, Error>?
        var oldFetch: CheckedContinuation<SimpleFinResponse, Error>?
        let newResponse = SimpleFinResponse(errors: [], accounts: [AccountDTO(
            id: "new-account", providerScope: "new.example", org: "New Bank",
            name: "Checking", currency: "USD", balance: 100,
            availableBalance: nil, balanceDate: Date(), transactions: []
        )])
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { storedURL },
            saveAccessURL: { storedURL = $0 },
            deleteAccessURL: { storedURL = nil },
            claim: { _ in
                try await withCheckedThrowingContinuation { claimContinuation = $0 }
            },
            fetch: { url, _ in
                if url == oldURL {
                    return try await withCheckedThrowingContinuation { oldFetch = $0 }
                }
                return newResponse
            }
        )

        let connectTask = Task { await coordinator.connect(setupToken: "new-token") }
        while claimContinuation == nil { await Task.yield() }
        // An auto-sync fires against the old URL while the claim is in flight,
        // freshly stamping the throttle.
        let oldTask = Task { await coordinator.sync() }
        while oldFetch == nil { await Task.yield() }
        claimContinuation?.resume(returning: newURL)
        await connectTask.value
        oldFetch?.resume(returning: SimpleFinResponse(errors: [], accounts: []))
        await oldTask.value

        for _ in 0..<100 where (try? container.mainContext.fetch(FetchDescriptor<Account>()))?.isEmpty == true {
            await Task.yield()
        }
        let account = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(account.providerScope, "new.example")
    }

    func testPipelineFailureRollsBackMutationsAndDoesNotStampSuccess() async throws {
        enum PipelineFailure: Error { case failed }
        let container = AppSchema.makeInMemoryContainer()
        let accessURL = URL(string: "https://user:pass@bridge.example/simplefin")!
        let coordinator = SyncCoordinator(
            context: container.mainContext,
            loadAccessURL: { accessURL },
            saveAccessURL: { _ in },
            deleteAccessURL: {},
            claim: { _ in accessURL },
            fetch: { _, _ in SimpleFinResponse(errors: [], accounts: []) },
            persist: { _, context in
                context.insert(Account(id: "partial", org: "", name: "Partial",
                                       currency: "USD", balance: 1, balanceDate: Date(),
                                       isManual: true))
                throw PipelineFailure.failed
            }
        )

        await coordinator.sync()

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertNil(coordinator.lastSyncDate)
        XCTAssertNotNil(coordinator.errorMessage)
    }
}
