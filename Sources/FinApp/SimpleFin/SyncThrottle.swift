import Foundation

/// Decides whether a sync may proceed, throttling rapid manual refreshes against
/// the user's SimpleFin account. Pure so it can be unit-tested.
enum SyncThrottle {
    static let minInterval: TimeInterval = 10

    static func shouldAllow(lastAttempt: Date?, now: Date, isSyncing: Bool, minInterval: TimeInterval) -> Bool {
        guard !isSyncing else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= minInterval
    }
}
