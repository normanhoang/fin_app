// Sources/FinApp/FinanceKit/FinanceKitClient.swift
import Foundation
#if FINANCEKIT
import FinanceKit
#endif

enum FinanceKitSources {
    /// Live store when compiled with FINANCEKIT on iOS 17.4+; otherwise a
    /// source that reports unavailable so the UI stays hidden.
    static func make() -> any FinanceKitSource {
        #if FINANCEKIT
        if #available(iOS 17.4, *) { return LiveFinanceKitSource() }
        #endif
        return UnavailableFinanceKitSource()
    }
}

#if FINANCEKIT
@available(iOS 17.4, *)
struct LiveFinanceKitSource: FinanceKitSource {
    private var store: FinanceStore { .shared }

    func isAvailable() -> Bool { FinanceStore.isDataAvailable(.financialData) }

    func authorizationStatus() async throws -> FKAuthorization { mapStatus(try await store.authorizationStatus()) }

    func requestAuthorization() async throws -> FKAuthorization { mapStatus(try await store.requestAuthorization()) }

    func fetch(since: Date) async throws -> [FKAccount] {
        let accounts = try await store.accounts(query: AccountQuery())
        let balances = try await store.accountBalances(query: AccountBalanceQuery())
        let latest = Dictionary(grouping: balances, by: \.accountID).compactMapValues { group in
            group.max { asOf($0) < asOf($1) }
        }
        let txns = try await store.transactions(query: TransactionQuery(
            predicate: #Predicate<FinanceKit.Transaction> { $0.transactionDate >= since }
        ))
        let txnsByAccount = Dictionary(grouping: txns, by: \.accountID)

        return accounts.map { account in
            let isLiability: Bool
            switch account {
            case .liability: isLiability = true
            case .asset: isLiability = false
            @unknown default: isLiability = false
            }
            let (booked, available) = latest[account.id].map(amounts) ?? (nil, nil)
            return FKAccount(
                id: account.id, institutionName: account.institutionName,
                displayName: account.displayName, currency: account.currencyCode,
                isLiability: isLiability, balance: booked ?? available ?? 0,
                availableBalance: available,
                balanceDate: latest[account.id].map(asOf) ?? Date(),
                transactions: (txnsByAccount[account.id] ?? []).map(mapTransaction)
            )
        }
    }

    private func mapStatus(_ status: AuthorizationStatus) -> FKAuthorization {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private func mapTransaction(_ t: FinanceKit.Transaction) -> FKTransaction {
        let status: FKTransaction.Status
        switch t.status {
        case .booked: status = .booked
        case .pending, .authorized: status = .pending
        case .rejected: status = .rejected
        case .memo: status = .memo
        @unknown default: status = .memo
        }
        return FKTransaction(
            id: t.id, posted: t.postedDate ?? t.transactionDate,
            amount: FinanceKitMapping.signed(t.transactionAmount.amount, isDebit: t.creditDebitIndicator == .debit),
            detail: t.transactionDescription, payee: t.merchantName, status: status
        )
    }

    private func signed(_ b: Balance) -> Decimal {
        FinanceKitMapping.signed(b.amount.amount, isDebit: b.creditDebitIndicator == .debit)
    }

    /// (booked, available), each signed.
    private func amounts(_ balance: AccountBalance) -> (Decimal?, Decimal?) {
        switch balance.currentBalance {
        case .booked(let b): (signed(b), nil)
        case .available(let a): (nil, signed(a))
        case .availableAndBooked(let a, let b): (signed(b), signed(a))
        @unknown default: (nil, nil)
        }
    }

    private func asOf(_ balance: AccountBalance) -> Date {
        switch balance.currentBalance {
        case .booked(let b), .available(let b): b.asOfDate
        case .availableAndBooked(_, let b): b.asOfDate
        @unknown default: .distantPast
        }
    }
}
#endif
