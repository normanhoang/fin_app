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
    static func sync(
        accounts dtos: [AccountDTO], pruneMissing: Bool = false,
        save: Bool = true, into context: ModelContext
    ) throws {
        let existingAccounts = try context.fetch(FetchDescriptor<Account>())
        let existingTxns = try context.fetch(FetchDescriptor<Transaction>())
        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        var accountsByID = Dictionary(existingAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var txnsByID = Dictionary(existingTxns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var legacyAccounts = Dictionary(
            grouping: existingAccounts.filter { !$0.isManual && $0.providerID == nil },
            by: \.id
        )
        var legacyTxns = Dictionary(grouping: existingTxns.filter { $0.providerID == nil }, by: \.id)
        // Already-migrated rows keyed by raw provider id, so an org whose scope
        // string changes (e.g. a bridge starts sending sfin-url) rekeys in place
        // instead of duplicating and pruning the original.
        let byProviderID = Dictionary(
            grouping: existingAccounts.filter { !$0.isManual && $0.providerID != nil },
            by: { $0.providerID! }
        )
        let dtoIDCounts = Dictionary(grouping: dtos, by: \.id).mapValues(\.count)
        let incomingIDs = Set(dtos.map {
            accountStorageID(providerScope: $0.providerScope, providerID: $0.id)
        })

        for dto in dtos {
            let accountID = accountStorageID(providerScope: dto.providerScope, providerID: dto.id)
            // When several orgs report the same raw id, corroborate the legacy
            // match with the org name instead of first-come-first-served.
            let legacyCandidates = legacyAccounts[dto.id] ?? []
            let legacyPool = dtoIDCounts[dto.id, default: 0] > 1
                ? legacyCandidates.filter { $0.org == dto.org }
                : legacyCandidates
            let legacy = legacyPool.count == 1 ? legacyPool.first : nil
            // Scope-change rekey: same raw id + org, different scoped id, and the
            // old row isn't claimed under its current id by another DTO.
            let rekeyCandidates = (byProviderID[dto.id] ?? []).filter {
                $0.id != accountID && $0.org == dto.org && !incomingIDs.contains($0.id)
            }
            let rekey = rekeyCandidates.count == 1 ? rekeyCandidates.first : nil
            let existing = accountsByID[accountID] ?? legacy ?? rekey
            let oldAccountID = existing?.id
            let account = upsertAccount(dto, storageID: accountID, existing: existing, in: context)
            accountsByID[accountID] = account
            if let legacy, existing === legacy { legacyAccounts[dto.id] = nil }
            if let oldAccountID, oldAccountID != accountID {
                for snapshot in snapshots where snapshot.accountId == oldAccountID {
                    snapshot.accountId = accountID
                }
                // Transactions were keyed under the old scoped account id — rekey
                // them so the upsert below matches in place instead of duplicating.
                for txn in existingTxns where txn.account === account {
                    guard let providerID = txn.providerID else { continue }
                    let newID = transactionStorageID(accountID: accountID, providerID: providerID)
                    if txn.id != newID {
                        txnsByID[txn.id] = nil
                        txn.id = newID
                        txnsByID[newID] = txn
                    }
                }
            }
            for txDTO in dto.transactions {
                let transactionID = transactionStorageID(accountID: accountID, providerID: txDTO.id)
                let matchingLegacy = legacyTxns[txDTO.id]?.filter {
                    $0.account === account || $0.account?.id == oldAccountID
                }
                let legacyTransaction = matchingLegacy?.count == 1 ? matchingLegacy?.first : nil
                let transaction = upsertTransaction(
                    txDTO, storageID: transactionID,
                    existing: txnsByID[transactionID] ?? legacyTransaction,
                    account: account, in: context
                )
                txnsByID[transactionID] = transaction
                if legacyTransaction != nil { legacyTxns[txDTO.id] = nil }
            }
            // Pending transactions are always current in a pending=1 response, so
            // a stored hold absent from a clean response was canceled by the bank
            // (or re-posted under a new id) — delete it so it stops inflating
            // spending. Posted rows are never pruned (the sync window is partial).
            if pruneMissing {
                let responseTxnIDs = Set(dto.transactions.map {
                    transactionStorageID(accountID: accountID, providerID: $0.id)
                })
                for txn in existingTxns
                    where txn.pending && txn.account === account && !responseTxnIDs.contains(txn.id) {
                    context.delete(txn)
                }
            }
        }
        // A synced account no longer in the response was removed from the SimpleFin
        // connection — delete it (transactions cascade) so its stale balance stops
        // counting toward net worth. Callers pass pruneMissing only when the response
        // reported no provider errors, so a bank outage never wipes data. Manual
        // accounts are never in the response and are never pruned.
        if pruneMissing {
            let dtoIDs = Set(dtos.map {
                accountStorageID(providerScope: $0.providerScope, providerID: $0.id)
            })
            for account in existingAccounts where !account.isManual && !dtoIDs.contains(account.id) {
                context.delete(account)
            }
        }
        if save { try context.save() }
    }

    static func accountStorageID(providerScope: String, providerID: String) -> String {
        "simplefin-account:\(providerScope.utf8.count):\(providerScope)\(providerID)"
    }

    static func transactionStorageID(accountID: String, providerID: String) -> String {
        "simplefin-transaction:\(accountID.utf8.count):\(accountID)\(providerID)"
    }

    @MainActor
    private static func upsertAccount(
        _ dto: AccountDTO, storageID: String, existing: Account?, in context: ModelContext
    ) -> Account {
        if let account = existing {
            account.id = storageID
            account.providerID = dto.id
            account.providerScope = dto.providerScope
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
            id: storageID, org: dto.org, name: dto.name, currency: dto.currency,
            balance: dto.balance, availableBalance: dto.availableBalance,
            balanceDate: dto.balanceDate,
            typeRaw: AccountTypeDetector.infer(name: dto.name, balance: dto.balance).rawValue
        )
        account.providerID = dto.id
        account.providerScope = dto.providerScope
        account.lastSyncedAt = Date()
        context.insert(account)
        return account
    }

    @MainActor
    private static func upsertTransaction(
        _ dto: TransactionDTO, storageID: String, existing: Transaction?,
        account: Account, in context: ModelContext
    ) -> Transaction {
        if let txn = existing {
            txn.id = storageID
            txn.providerID = dto.id
            txn.posted = dto.posted
            txn.amount = dto.amount
            txn.detail = dto.detail
            txn.payee = dto.payee
            txn.memo = dto.memo
            txn.pending = dto.pending
            txn.account = account
            return txn
        }

        let txn = Transaction(
            id: storageID, posted: dto.posted, amount: dto.amount, detail: dto.detail,
            payee: dto.payee, memo: dto.memo, pending: dto.pending, account: account
        )
        txn.providerID = dto.id
        context.insert(txn)
        return txn
    }
}
