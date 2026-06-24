import Foundation
import SwiftData

/// Upserts decoded SimpleFin data into the SwiftData store. Keyed by SimpleFin
/// ids so re-syncing the same data is idempotent and pending→posted updates
/// land in place. Networking lives in `SimpleFinClient`; this is pure persistence.
///
/// Existing rows are preloaded into id-keyed maps in one fetch each, rather than
/// a per-item predicated fetch — simpler, faster, and avoids `#Predicate`.
enum SyncService {
    @MainActor
    static func sync(accounts dtos: [AccountDTO], into context: ModelContext) {
        let existingAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let existingTxns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let accountsByID = Dictionary(existingAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let txnsByID = Dictionary(existingTxns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for dto in dtos {
            let account = upsertAccount(dto, existing: accountsByID[dto.id], in: context)
            applyBalanceCorrection(account)
            for txDTO in dto.transactions {
                upsertTransaction(txDTO, existing: txnsByID[txDTO.id], account: account, in: context)
            }
        }
        try? context.save()
    }

    /// Per-account correction: Bank of America Checking reports the real balance in
    /// `available-balance`, so swap the two fields. Re-applied each sync (idempotent)
    /// since the DTO overwrites the fields on every upsert. Fixes net worth too.
    @MainActor
    private static func applyBalanceCorrection(_ account: Account) {
        let name = account.displayName.lowercased()
        guard name.contains("bank of america"), name.contains("checking"),
              let available = account.availableBalance else { return }
        let original = account.balance
        account.balance = available
        account.availableBalance = original
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
            return account
        }

        let account = Account(
            id: dto.id, org: dto.org, name: dto.name, currency: dto.currency,
            balance: dto.balance, availableBalance: dto.availableBalance,
            balanceDate: dto.balanceDate
        )
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
