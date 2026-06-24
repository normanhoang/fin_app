import XCTest
@testable import FinApp

final class SyncThrottleTests: XCTestCase {
    private let interval: TimeInterval = 10
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAllowsFirstSync() {
        XCTAssertTrue(SyncThrottle.shouldAllow(lastAttempt: nil, now: now, isSyncing: false, minInterval: interval))
    }

    func testBlocksWhileSyncInFlight() {
        XCTAssertFalse(SyncThrottle.shouldAllow(lastAttempt: nil, now: now, isSyncing: true, minInterval: interval))
    }

    func testBlocksWithinInterval() {
        let recent = now.addingTimeInterval(-3)
        XCTAssertFalse(SyncThrottle.shouldAllow(lastAttempt: recent, now: now, isSyncing: false, minInterval: interval))
    }

    func testAllowsAfterInterval() {
        let old = now.addingTimeInterval(-11)
        XCTAssertTrue(SyncThrottle.shouldAllow(lastAttempt: old, now: now, isSyncing: false, minInterval: interval))
    }
}
