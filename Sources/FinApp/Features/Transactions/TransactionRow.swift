import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                .foregroundStyle(Color(hex: transaction.category?.colorHex ?? "#8E8E93"))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payee ?? transaction.detail)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(transaction.posted, format: .dateTime.month().day())
                    if let name = transaction.category?.name {
                        Text("· \(name)")
                    }
                    if transaction.pending {
                        Text("· Pending").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.string(transaction.amount))
                .foregroundStyle(transaction.isInflow ? .green : .primary)
                .monospacedDigit()
        }
    }
}
