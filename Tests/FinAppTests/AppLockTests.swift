import XCTest
import LocalAuthentication
@testable import FinApp

@MainActor
final class AppLockTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "appLockEnabled")
        super.tearDown()
    }

    private func makeLockedLock() -> AppLock {
        let lock = AppLock()
        lock.isEnabled = true
        lock.lock()
        return lock
    }

    // MARK: authenticate

    func testSuccessUnlocksAndClearsError() async {
        let lock = makeLockedLock()
        lock.evaluator = { _ in true }
        await lock.authenticate()
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertNil(lock.lastError)
    }

    func testFailureStaysLocked() async {
        let lock = makeLockedLock()
        lock.evaluator = { _ in throw LAError(.authenticationFailed) }
        await lock.authenticate()
        XCTAssertFalse(lock.isUnlocked)
    }

    // MARK: error mapping

    func testCancelErrorsProduceNoMessage() async {
        for code: LAError.Code in [.userCancel, .systemCancel, .appCancel, .notInteractive] {
            let lock = makeLockedLock()
            lock.evaluator = { _ in throw LAError(code) }
            await lock.authenticate()
            XCTAssertNil(lock.lastError, "expected no message for \(code)")
            XCTAssertFalse(lock.isUnlocked)
        }
    }

    func testLockoutProducesFriendlyMessage() async throws {
        let lock = makeLockedLock()
        lock.evaluator = { _ in throw LAError(.biometryLockout) }
        await lock.authenticate()
        let message = try XCTUnwrap(lock.lastError)
        XCTAssertFalse(message.contains("com.apple.LocalAuthentication"),
                       "raw NSError text leaked to UI: \(message)")
    }

    func testBiometryNotAvailableProducesFriendlyMessage() async throws {
        let lock = makeLockedLock()
        lock.evaluator = { _ in throw LAError(.biometryNotAvailable) }
        await lock.authenticate()
        let message = try XCTUnwrap(lock.lastError)
        XCTAssertFalse(message.contains("com.apple.LocalAuthentication"),
                       "raw NSError text leaked to UI: \(message)")
    }

    // MARK: autoAuthenticate — once per lock cycle

    func testAutoAuthenticateRunsOnlyOncePerLockCycle() async {
        let lock = makeLockedLock()
        var attempts = 0
        lock.evaluator = { _ in
            attempts += 1
            throw LAError(.userCancel)
        }
        await lock.autoAuthenticate()
        await lock.autoAuthenticate()
        XCTAssertEqual(attempts, 1, "second auto attempt must be a no-op")
    }

    func testLockRearmsAutoAuthenticate() async {
        let lock = makeLockedLock()
        var attempts = 0
        lock.evaluator = { _ in
            attempts += 1
            throw LAError(.userCancel)
        }
        await lock.autoAuthenticate()
        lock.lock()
        await lock.autoAuthenticate()
        XCTAssertEqual(attempts, 2, "lock() should re-arm the auto attempt")
    }

    func testManualAuthenticateNotGatedByAutoGuard() async {
        let lock = makeLockedLock()
        var attempts = 0
        lock.evaluator = { _ in
            attempts += 1
            throw LAError(.userCancel)
        }
        await lock.autoAuthenticate()
        await lock.authenticate() // user tapped Unlock
        XCTAssertEqual(attempts, 2)
    }
}
