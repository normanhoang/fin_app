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
    /// Debit = money out of the user's pocket (purchase, or balance owed on a
    /// card) → negative; credit → positive. Single place to flip if device
    /// testing shows FinanceKit reports card balances the other way.
    static func signed(_ amount: Decimal, isDebit: Bool) -> Decimal {
        isDebit ? -amount.magnitude : amount.magnitude
    }
}
