// Sources/FinApp/FinanceKit/FinanceKitCoordinator.swift
import Foundation
import SwiftData
import Observation

enum FKAuthorization: Sendable { case notDetermined, authorized, denied }

/// Seam over `FinanceStore` so the coordinator is testable without FinanceKit
/// (which the Simulator doesn't support). Live impl: `LiveFinanceKitSource`.
protocol FinanceKitSource: Sendable {
    func isAvailable() -> Bool
    func authorizationStatus() async throws -> FKAuthorization
    func requestAuthorization() async throws -> FKAuthorization
    /// Accounts + balances + transactions on or after `since`.
    func fetch(since: Date) async throws -> [FKAccount]
}

/// Used when the FINANCEKIT flag is off or iOS < 17.4: hides the feature.
struct UnavailableFinanceKitSource: FinanceKitSource {
    func isAvailable() -> Bool { false }
    func authorizationStatus() async throws -> FKAuthorization { .denied }
    func requestAuthorization() async throws -> FKAuthorization { .denied }
    func fetch(since: Date) async throws -> [FKAccount] { [] }
}

#if DEBUG
/// `FINAPP_FK_DEMO=1`: an authorized source with no data, so the Simulator can
/// show the connected Apple Wallet card (design review / UI tests).
struct DemoFinanceKitSource: FinanceKitSource {
    func isAvailable() -> Bool { true }
    func authorizationStatus() async throws -> FKAuthorization { .authorized }
    func requestAuthorization() async throws -> FKAuthorization { .authorized }
    func fetch(since: Date) async throws -> [FKAccount] { [] }
}
#endif

struct MergeProposal: Equatable, Identifiable {
    let financeKitAccountID: String
    let simplefinAccountID: String
    let financeKitName: String
    let simplefinName: String
    var id: String { financeKitAccountID }
}

/// Orchestrates FinanceKit authorization + import (Apple Card/Cash/Savings).
/// UI-facing observable state; mirrors `SyncCoordinator`.
@MainActor
@Observable
final class FinanceKitCoordinator {
    static let minImportInterval: TimeInterval = 300
    private static let lastImportKey = "financeKitLastImportDate"
    private static let declinedKey = "financeKitMergeDeclined"

    private let source: any FinanceKitSource
    private let context: ModelContext
    private let now: () -> Date
    private var lastAttempt: Date?

    let isAvailable: Bool
    private(set) var authorization: FKAuthorization = .notDetermined
    private(set) var isImporting = false
    var errorMessage: String?
    var pendingMerge: MergeProposal?
    var lastMergeResult: FinanceKitMerge.Result?

    var lastImportDate: Date? {
        didSet { UserDefaults.standard.set(lastImportDate, forKey: Self.lastImportKey) }
    }

    private var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.declinedKey) }
    }

    init(source: any FinanceKitSource, context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.context = context
        self.now = now
        self.isAvailable = source.isAvailable()
        self.lastImportDate = UserDefaults.standard.object(forKey: Self.lastImportKey) as? Date
    }

    func refreshAuthorization() async {
        guard isAvailable else { return }
        authorization = (try? await source.authorizationStatus()) ?? .notDetermined
    }

    /// Shows the system account picker, then imports what the user granted.
    func connect() async {
        guard isAvailable else { return }
        do {
            authorization = try await source.requestAuthorization()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        await importNow()
    }

    /// On-device data, so no server throttle — just debounce rapid foregrounds.
    func importIfStale(minInterval: TimeInterval = FinanceKitCoordinator.minImportInterval) async {
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < minInterval { return }
        await refreshAuthorization()
        guard authorization == .authorized else { return }
        await importNow()
    }

    func importNow() async {
        guard isAvailable, !isImporting else { return }
        if authorization != .authorized { await refreshAuthorization() }
        guard authorization == .authorized else { return }
        isImporting = true
        defer { isImporting = false }
        lastAttempt = now()
        errorMessage = nil
        do {
            var accounts = try await source.fetch(since: fetchStart())
            // An account shared since the last import gets the first-import lookback.
            if lastImportDate != nil, try hasUnseenAccount(accounts) {
                accounts = try await source.fetch(since: fetchStart(initial: true))
            }
            do {
                try FinanceKitImporter.stage(accounts, into: context)
                try SyncCoordinator.stageDerivedData(in: context)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            lastImportDate = now()
            proposeMergeIfNeeded()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func confirmMerge() {
        guard let proposal = pendingMerge else { return }
        pendingMerge = nil
        guard let all = try? context.fetch(FetchDescriptor<Account>()),
              let fk = all.first(where: { $0.id == proposal.financeKitAccountID }),
              let old = all.first(where: { $0.id == proposal.simplefinAccountID }) else { return }
        do {
            lastMergeResult = try FinanceKitMerge.merge(fk, into: old, in: context)
            try SyncCoordinator.stageDerivedData(in: context)
            try context.save()
        } catch {
            context.rollback()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clears the prompt without remembering a decline, so it returns on the next import.
    func dismissMergeProposal() { pendingMerge = nil }

    func declineMerge() {
        guard let proposal = pendingMerge else { return }
        declined.insert(proposal.financeKitAccountID)
        pendingMerge = nil
    }

    /// Checked after every import (not just first insert) so an unanswered
    /// prompt — app killed mid-sheet — comes back next time.
    private func proposeMergeIfNeeded() {
        guard pendingMerge == nil, let all = try? context.fetch(FetchDescriptor<Account>()) else { return }
        let declined = declined
        for fk in all where fk.source == .financeKit && fk.supersededProviderID == nil
            && !declined.contains(fk.id) {
            if let old = FinanceKitMerge.candidate(for: fk, among: all) {
                pendingMerge = MergeProposal(financeKitAccountID: fk.id, simplefinAccountID: old.id,
                                             financeKitName: fk.displayName, simplefinName: old.displayName)
                return
            }
        }
    }

    private func hasUnseenAccount(_ accounts: [FKAccount]) throws -> Bool {
        let stored = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id))
        return accounts.contains { !stored.contains(FinanceKitImporter.accountStorageID($0.id)) }
    }

    private func fetchStart(initial: Bool = false) -> Date {
        let days: Int
        if !initial, let last = lastImportDate {
            let elapsed = Calendar.current.dateComponents([.day], from: last, to: now()).day ?? 0
            days = elapsed + SyncCoordinator.resyncOverlapDays
        } else {
            days = SyncCoordinator.initialLookbackDays
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: now()) ?? now()
    }
}
