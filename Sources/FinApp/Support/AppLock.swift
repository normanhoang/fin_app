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

    var isEnabled: Bool {
        didSet {
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
        if isEnabled { isUnlocked = false }
    }

    func authenticate() async {
        guard isEnabled, !isUnlocked else { return }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock to view your financial data"
            )
            isUnlocked = ok
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
