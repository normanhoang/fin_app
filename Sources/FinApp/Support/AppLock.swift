import Foundation
import LocalAuthentication
import Observation

/// Optional biometric/passcode gate shown before financial data. When enabled,
/// the app starts locked and re-locks when sent to the background.
@MainActor
@Observable
final class AppLock {
    private let enabledKey = "appLockEnabled"

    var isUnlocked: Bool
    var lastError: String?

    /// One automatic Face ID prompt per lock cycle; `lock()` re-arms it.
    private var autoAttempted = false
    /// Invalidates authentication results that return after a later lock or
    /// enable/disable transition.
    private var generation = 0

    /// Injectable for tests; production evaluates the device-owner policy.
    /// Must only be invoked while the app is foreground-active — LocalAuthentication
    /// fails with biometryNotAvailable (-6) otherwise.
    var evaluator: (String) async throws -> Bool = { reason in
        try await LAContext().evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }

    var isEnabled: Bool {
        didSet {
            generation += 1
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if isEnabled { isUnlocked = true } // just enabled in an unlocked session
        }
    }

    init() {
        let enabled = UserDefaults.standard.bool(forKey: enabledKey)
        isEnabled = enabled
        isUnlocked = !enabled
    }

    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        if isEnabled {
            generation += 1
            isUnlocked = false
            autoAttempted = false
        }
    }

    /// Automatic prompt when the lock screen becomes active — at most once per
    /// lock cycle, so a user cancel doesn't retrigger Face ID in a loop when the
    /// scene flips inactive → active around the system prompt.
    func autoAuthenticate() async {
        guard !autoAttempted else { return }
        autoAttempted = true
        await authenticate()
    }

    func authenticate() async {
        guard isEnabled, !isUnlocked else { return }
        let attemptGeneration = generation
        do {
            let authenticated = try await evaluator("Unlock to view your financial data")
            guard attemptGeneration == generation, isEnabled, !isUnlocked else { return }
            isUnlocked = authenticated
            lastError = nil
        } catch {
            guard attemptGeneration == generation, isEnabled, !isUnlocked else { return }
            lastError = Self.friendlyMessage(for: error)
        }
    }

    /// nil for expected cancellations (no UI noise); short human-readable text
    /// for real failures instead of the raw NSError description.
    static func friendlyMessage(for error: Error) -> String? {
        guard let laError = error as? LAError else { return error.localizedDescription }
        switch laError.code {
        case .userCancel, .systemCancel, .appCancel, .notInteractive:
            return nil
        case .biometryLockout:
            return "Face ID is locked after too many attempts. Tap Unlock to use your passcode."
        case .biometryNotAvailable, .biometryNotEnrolled:
            return "Face ID isn't available right now. Tap Unlock to use your passcode."
        case .passcodeNotSet:
            return "Set a device passcode in Settings to use App Lock."
        default:
            return "Couldn't unlock. Tap Unlock to try again."
        }
    }
}
