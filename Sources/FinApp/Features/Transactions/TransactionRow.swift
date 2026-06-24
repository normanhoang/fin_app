import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction

    private var categoryColor: Color { Color(hex: transaction.category?.colorHex ?? "#8E8E93") }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(categoryColor.opacity(0.15))
                Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(categoryColor)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.payee ?? transaction.detail)
                    .foregroundStyle(Color.textPrimary)
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
                .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            MoneyText(value: transaction.amount, size: 16, weight: .semibold,
                      color: transaction.isInflow ? .positive : .textPrimary)
        }
        .padding(.vertical, 2)
    }
}
