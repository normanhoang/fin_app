import Foundation
import SwiftData
import Observation

/// Orchestrates connect + sync: SimpleFinClient (network) → CredentialStore
/// (Keychain) → SyncService (persistence). UI-facing observable state.
@MainActor
@Observable
final class SyncCoordinator {
    /// First sync pulls this much history; SimpleFin returns no transactions
    /// without a start-date.
    static let initialLookbackDays = 120
    /// Re-fetch a small overlap before last sync to catch late-posting items.
    static let resyncOverlapDays = 5

    private let store: CredentialStore
    private let client: SimpleFinClient
    private let context: ModelContext
    private let lastSyncKey = "lastSyncDate"

    var isSyncing = false
    private var lastSyncAttempt: Date?
    var errorMessage: String?
    /// Non-fatal messages from SimpleFin's `errors` array (e.g. a bank needing re-auth).
    var providerErrors: [String] = []

    /// Stored (not computed from the Keychain) so SwiftUI observes connect/disconnect
    /// and re-renders. Kept in sync with the stored access URL by `connect`/`disconnect`.
    private(set) var isConnected: Bool

    init(store: CredentialStore = CredentialStore(), client: SimpleFinClient = SimpleFinClient(), context: ModelContext) {
        self.store = store
        self.client = client
        self.context = context
        self.isConnected = store.loadAccessURL() != nil
    }

    var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }

    /// Claim a setup token, store the access URL, then sync.
    func connect(setupToken: String) async {
        errorMessage = nil
        do {
            let accessURL = try await client.claim(setupToken: setupToken)
            try store.saveAccessURL(accessURL)
            isConnected = true
            await sync()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func sync() async {
        guard SyncThrottle.shouldAllow(lastAttempt: lastSyncAttempt, now: Date(),
                                       isSyncing: isSyncing, minInterval: SyncThrottle.minInterval) else { return }
        lastSyncAttempt = Date()

        guard let accessURL = store.loadAccessURL() else {
            errorMessage = SimpleFinError.invalidAccessURL.errorDescription
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            CategorySeed.seedIfNeeded(in: context)
            CategorySeed.ensureMissing(in: context)
            let response = try await client.fetchAccounts(accessURL: accessURL, since: nextSyncStartDate())
            // Prune accounts removed from the connection only on a clean response —
            // a provider error can mean a bank's accounts are temporarily missing.
            SyncService.sync(accounts: response.accounts,
                             pruneMissing: response.errors.isEmpty, into: context)
            CategorizationEngine.categorizeAll(in: context)
            RecurringDetector.refresh(in: context)
            recordNetWorthSnapshot()
            providerErrors = response.errors
            lastSyncDate = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Auto-sync on app open only when it's been over an hour since the last
    /// successful sync, so a quick reopen doesn't re-hit SimpleFin every time.
    func syncIfStale(maxAge: TimeInterval = 3600) async {
        if let last = lastSyncDate, Date().timeIntervalSince(last) < maxAge { return }
        await sync()
    }

    func disconnect() {
        store.deleteAccessURL()
        isConnected = false
        lastSyncDate = nil
        providerErrors = []
    }

    /// Snapshot current net worth so the dashboard graph builds history over time.
    private func recordNetWorthSnapshot() {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        NetWorthSnapshotService.record(value: Analytics.netWorth(accounts), in: context)
    }

    private func nextSyncStartDate() -> Date {
        let days: Int
        if let last = lastSyncDate {
            let elapsed = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
            days = elapsed + Self.resyncOverlapDays
        } else {
            days = Self.initialLookbackDays
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }
}
