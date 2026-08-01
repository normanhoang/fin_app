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

    private let context: ModelContext
    private let loadAccessURL: () -> URL?
    private let saveAccessURL: (URL) throws -> Void
    private let deleteAccessURL: () -> Void
    private let claimSetupToken: (String) async throws -> URL
    private let fetchAccounts: (URL, Date?) async throws -> SimpleFinResponse
    private let persistResponse: (SimpleFinResponse, ModelContext) throws -> Void
    private let lastSyncKey = "lastSyncDate"
    private var connectionGeneration = 0
    private var pendingSyncGeneration: Int?

    var isSyncing = false
    private var lastSyncAttempt: Date?
    var errorMessage: String?
    /// Non-fatal messages from SimpleFin's `errors` array (e.g. a bank needing re-auth).
    var providerErrors: [String] = []

    /// Stored (not computed from the Keychain) so SwiftUI observes connect/disconnect
    /// and re-renders. Kept in sync with the stored access URL by `connect`/`disconnect`.
    private(set) var isConnected: Bool

    init(store: CredentialStore = CredentialStore(), client: SimpleFinClient = SimpleFinClient(), context: ModelContext) {
        self.context = context
        self.loadAccessURL = { store.loadAccessURL() }
        self.saveAccessURL = { try store.saveAccessURL($0) }
        self.deleteAccessURL = { _ = store.deleteAccessURL() }
        self.claimSetupToken = { try await client.claim(setupToken: $0) }
        self.fetchAccounts = { try await client.fetchAccounts(accessURL: $0, since: $1) }
        self.persistResponse = { try SyncCoordinator.persist($0, in: $1) }
        self.isConnected = store.loadAccessURL() != nil
    }

    init(
        context: ModelContext,
        loadAccessURL: @escaping () -> URL?,
        saveAccessURL: @escaping (URL) throws -> Void,
        deleteAccessURL: @escaping () -> Void,
        claim: @escaping (String) async throws -> URL,
        fetch: @escaping (URL, Date?) async throws -> SimpleFinResponse,
        persist: @escaping (SimpleFinResponse, ModelContext) throws -> Void = {
            try SyncCoordinator.persist($0, in: $1)
        }
    ) {
        self.context = context
        self.loadAccessURL = loadAccessURL
        self.saveAccessURL = saveAccessURL
        self.deleteAccessURL = deleteAccessURL
        self.claimSetupToken = claim
        self.fetchAccounts = fetch
        self.persistResponse = persist
        self.isConnected = loadAccessURL() != nil
    }

    var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }

    /// Claim a setup token, store the access URL, then sync.
    func connect(setupToken: String) async {
        errorMessage = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        lastSyncAttempt = nil
        do {
            let accessURL = try await claimSetupToken(setupToken)
            guard generation == connectionGeneration else { return }
            try saveAccessURL(accessURL)
            isConnected = true
            await performSync(queueIfBusy: true)
        } catch {
            guard generation == connectionGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func sync() async {
        await performSync(queueIfBusy: false)
    }

    private func performSync(queueIfBusy: Bool) async {
        if isSyncing {
            if queueIfBusy { pendingSyncGeneration = connectionGeneration }
            return
        }
        guard SyncThrottle.shouldAllow(lastAttempt: lastSyncAttempt, now: Date(),
                                       isSyncing: isSyncing, minInterval: SyncThrottle.minInterval) else { return }
        guard let accessURL = loadAccessURL() else {
            errorMessage = SimpleFinError.invalidAccessURL.errorDescription
            return
        }
        errorMessage = nil
        providerErrors = []
        lastSyncAttempt = Date()
        let generation = connectionGeneration
        isSyncing = true
        defer {
            isSyncing = false
            if pendingSyncGeneration == connectionGeneration {
                pendingSyncGeneration = nil
                // The queued sync was promised (post-connect) — clear the throttle
                // stamp so it isn't silently dropped for starting too soon.
                lastSyncAttempt = nil
                Task { await self.sync() }
            }
        }

        do {
            // Category seeding runs at launch (FinAppApp.init); no need per sync.
            let response = try await fetchAccounts(accessURL, nextSyncStartDate())
            guard generation == connectionGeneration,
                  loadAccessURL() == accessURL,
                  isConnected else { throw CancellationError() }
            do {
                try persistResponse(response, context)
            } catch {
                // Discard partially staged sync data. Errors before staging never
                // roll back — the shared main context may hold unsaved user edits.
                context.rollback()
                throw error
            }
            providerErrors = response.errors
            lastSyncDate = Date()
            errorMessage = nil
        } catch is CancellationError {
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
        connectionGeneration += 1
        pendingSyncGeneration = nil
        deleteAccessURL()
        isConnected = false
        lastSyncAttempt = nil
        lastSyncDate = nil
        providerErrors = []
        errorMessage = nil
    }

    /// Snapshot current net worth (dashboard graph) and per-account balances
    /// (account-row sparklines) so both build history over time.
    static func persist(_ response: SimpleFinResponse, in context: ModelContext) throws {
        // Prune accounts removed from the connection only on a clean response —
        // a provider error can mean a bank's accounts are temporarily missing.
        try SyncService.sync(accounts: response.accounts,
                             pruneMissing: response.errors.isEmpty,
                             save: false, into: context)
        let txns = try context.fetch(FetchDescriptor<Transaction>())
        try CategorizationEngine.stageCategorizeAll(txns, in: context)
        try RecurringDetector.stageRefresh(txns, in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        try NetWorthSnapshotService.stage(value: Analytics.netWorth(accounts), in: context)
        try AccountBalanceSnapshotService.stage(accounts, in: context)
        try context.save()
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
