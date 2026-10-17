import Foundation

/// FinanceKit data mapped to plain values (amounts already signed per app
/// convention), so the importer and tests never touch FinanceKit types.
struct FKTransaction: Equatable, Sendable {
    enum Status: Sendable { case booked, pending, rejected, memo }
    let id: UUID
    let posted: Date
    let amount: Decimal
    let detail: String
    let payee: String?
    let status: Status
}

struct FKAccount: Equatable, Sendable {
    let id: UUID
    let institutionName: String
    let displayName: String
    let currency: String
    let isLiability: Bool
    let balance: Decimal
    let availableBalance: Decimal?
    let balanceDate: Date
    let transactions: [FKTransaction]
}

enum FinanceKitMapping {
    /// Transactions: debit = money out (purchase) → negative; credit → positive.
    static func signed(_ amount: Decimal, isDebit: Bool) -> Decimal {
        isDebit ? -amount.magnitude : amount.magnitude
    }

    /// Balances use the accounting indicator instead (seen on device: Apple Cash
    /// holding money is `.debit`, an Apple Card amount owed is `.credit`). Asset
    /// balances (Cash/Savings) can't be overdrawn, so they're always positive —
    /// robust to Apple's inconsistent asset indicator. A liability owed (credit)
    /// is negative; overpaid (debit) is positive.
    static func balance(_ amount: Decimal, isDebit: Bool, isLiability: Bool) -> Decimal {
        guard isLiability else { return amount.magnitude }
        return isDebit ? amount.magnitude : -amount.magnitude
    }
}
