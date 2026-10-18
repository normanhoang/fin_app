import Foundation
import SwiftData

/// Upserts FinanceKit data into SwiftData. Pure persistence (no FinanceKit
/// import) so it is unit-tested with plain DTOs. Mirrors `SyncService`.
enum FinanceKitImporter {
    static func accountStorageID(_ id: UUID) -> String { "financekit-\(id.uuidString)" }

    static func transactionStorageID(accountID: UUID, transactionID: UUID) -> String {
        "financekit-\(accountID.uuidString)-\(transactionID.uuidString)"
    }

    /// Stages (no save) a complete FinanceKit fetch. Callers pass only a fetch
    /// that succeeded, so FinanceKit accounts absent from it were revoked or
    /// removed and are deleted (transactions cascade). Pruning is skipped for an
    /// empty fetch, and merged accounts (`supersededProviderID != nil`) are never
    /// pruned: they carry the user's pre-FinanceKit history.
    @MainActor
    static func stage(_ dtos: [FKAccount], into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Account>())
        let accountsByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingTxns = try context.fetch(FetchDescriptor<Transaction>())
        let txnsByID = Dictionary(existingTxns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for dto in dtos {
            let account = upsertAccount(dto, existing: accountsByID[accountStorageID(dto.id)], in: context)
            var fetched = Set<String>()
            for txDTO in dto.transactions {
                let id = transactionStorageID(accountID: dto.id, transactionID: txDTO.id)
                fetched.insert(id)
                switch txDTO.status {
                case .memo:
                    continue
                case .rejected:
                    if let txn = txnsByID[id] { context.delete(txn) }
                case .booked, .pending:
                    upsertTransaction(txDTO, storageID: id, existing: txnsByID[id], account: account, in: context)
                }
            }
            // Holds are always recent, so a stored pending row absent from the fetch
            // was dropped by Apple without a .rejected status — delete it so it stops
            // inflating spending. Booked rows are never pruned (the window is partial).
            for txn in existingTxns where txn.pending && txn.account === account && !fetched.contains(txn.id) {
                context.delete(txn)
            }
        }

        guard !dtos.isEmpty else { return }
        let incoming = Set(dtos.map { accountStorageID($0.id) })
        for account in existing
        where account.source == .financeKit && account.supersededProviderID == nil && !incoming.contains(account.id) {
            context.delete(account)
        }
    }

    @MainActor
    private static func upsertAccount(_ dto: FKAccount, existing: Account?, in context: ModelContext) -> Account {
        let account = existing ?? {
            let a = Account(
                id: accountStorageID(dto.id), org: dto.institutionName, name: dto.displayName,
                currency: dto.currency, balance: dto.balance, balanceDate: dto.balanceDate,
                typeRaw: (dto.isLiability ? AccountType.creditCard : .cash).rawValue
            )
            a.source = .financeKit
            a.providerID = dto.id.uuidString
            a.createdAt = Date()
            context.insert(a)
            return a
        }()
        // Never written here: customName, customSortIndex, typeRaw (after insert).
        account.org = dto.institutionName
        account.name = dto.displayName
        account.currency = dto.currency
        account.balance = dto.balance
        account.availableBalance = dto.availableBalance
        account.balanceDate = dto.balanceDate
        account.lastSyncedAt = Date()
        return account
    }

    @MainActor
    private static func upsertTransaction(
        _ dto: FKTransaction, storageID: String, existing: Transaction?,
        account: Account, in context: ModelContext
    ) {
        // Never written here: note, category, categorizedByUser.
        let txn = existing ?? {
            let t = Transaction(id: storageID, posted: dto.posted, amount: dto.amount, detail: dto.detail)
            t.providerID = dto.id.uuidString
            context.insert(t)
            return t
        }()
        txn.posted = dto.posted
        txn.amount = dto.amount
        txn.detail = dto.detail
        txn.payee = dto.payee
        txn.pending = dto.status == .pending
        txn.account = account
    }
}
