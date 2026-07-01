import SwiftUI
import SwiftData

struct TransactionRow: View {
    let transaction: Transaction

    @Query(sort: \Category.name) private var categories: [Category]
    @Environment(\.modelContext) private var context
    @State private var showCategoryPicker = false

    private var categoryColor: Color { Color(hex: transaction.category?.colorHex ?? "#8E8E93") }

    var body: some View {
        HStack(spacing: 12) {
            // Tap the icon to change just this transaction's category; the rest
            // of the row keeps its own tap (open detail). A Button nests cleanly
            // inside the row's enclosing Button/NavigationLink in a List.
            Button {
                showCategoryPicker = true
            } label: {
                ZStack {
                    Circle().fill(categoryColor.opacity(0.15))
                    Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(categoryColor)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("categoryIcon-\(transaction.id)")
            .popover(isPresented: $showCategoryPicker) {
                CategoryPickerPopup(
                    categories: categories,
                    selectedName: transaction.category?.name,
                    isUncategorizedSelected: transaction.category == nil,
                    onSelect: { CategorizationEngine.assign($0, to: transaction, in: context) }
                )
                .presentationCompactAdaptation(.popover)
            }
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
                      color: balanceColor(transaction.amount))
        }
        .padding(.vertical, 2)
    }
}
