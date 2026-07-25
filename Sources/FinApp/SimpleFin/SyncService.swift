import Foundation
import SwiftData

/// Upserts decoded SimpleFin data into the SwiftData store. Keyed by SimpleFin
/// ids so re-syncing the same data is idempotent and pending→posted updates
/// land in place. Networking lives in `SimpleFinClient`; this is pure persistence.
///
/// Existing rows are preloaded into id-keyed maps in one fetch each, rather than
/// a per-item predicated fetch — simpler, faster, and avoids `#Predicate`.
enum SyncService {
    /// Throws if the final save fails — callers must surface it, since a failed
    /// save after the prune deletes below would silently diverge from the store.
    @MainActor
    static func sync(accounts dtos: [AccountDTO], pruneMissing: Bool = false, into context: ModelContext) throws {
        let existingAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let existingTxns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let accountsByID = Dictionary(existingAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let txnsByID = Dictionary(existingTxns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for dto in dtos {
            let account = upsertAccount(dto, existing: accountsByID[dto.id], in: context)
            for txDTO in dto.transactions {
                upsertTransaction(txDTO, existing: txnsByID[txDTO.id], account: account, in: context)
            }
        }
        // A synced account no longer in the response was removed from the SimpleFin
        // connection — delete it (transactions cascade) so its stale balance stops
        // counting toward net worth. Callers pass pruneMissing only when the response
        // reported no provider errors, so a bank outage never wipes data. Manual
        // accounts are never in the response and are never pruned.
        if pruneMissing {
            let dtoIDs = Set(dtos.map(\.id))
            for account in existingAccounts where !account.isManual && !dtoIDs.contains(account.id) {
                context.delete(account)
            }
        }
        try context.save()
    }

    @MainActor
    private static func upsertAccount(_ dto: AccountDTO, existing: Account?, in context: ModelContext) -> Account {
        if let account = existing {
            account.org = dto.org
            account.name = dto.name
            account.currency = dto.currency
            account.balance = dto.balance
            account.availableBalance = dto.availableBalance
            account.balanceDate = dto.balanceDate
            account.lastSyncedAt = Date()
            return account
        }

        let account = Account(
            id: dto.id, org: dto.org, name: dto.name, currency: dto.currency,
            balance: dto.balance, availableBalance: dto.availableBalance,
            balanceDate: dto.balanceDate,
            typeRaw: AccountTypeDetector.infer(name: dto.name, balance: dto.balance).rawValue
        )
        account.lastSyncedAt = Date()
        context.insert(account)
        return account
    }

    @MainActor
    private static func upsertTransaction(_ dto: TransactionDTO, existing: Transaction?, account: Account, in context: ModelContext) {
        if let txn = existing {
            txn.posted = dto.posted
            txn.amount = dto.amount
            txn.detail = dto.detail
            txn.payee = dto.payee
            txn.memo = dto.memo
            txn.pending = dto.pending
            txn.account = account
            return
        }

        let txn = Transaction(
            id: dto.id, posted: dto.posted, amount: dto.amount, detail: dto.detail,
            payee: dto.payee, memo: dto.memo, pending: dto.pending, account: account
        )
        context.insert(txn)
    }
}
