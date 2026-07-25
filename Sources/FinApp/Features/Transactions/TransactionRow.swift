import SwiftUI
import SwiftData

struct TransactionRow: View {
    let transaction: Transaction

    @State private var showCategoryPicker = false

    private var categoryColor: Color { Color(hex: transaction.category?.colorHex ?? "#8E8E93") }

    /// Fee/penalty rows are the one outflow that stays red. Word-bounded so
    /// "coffee" doesn't match.
    private var isFee: Bool {
        transaction.amount < 0 && (transaction.payee ?? transaction.detail)
            .range(of: #"\bfees?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Tap the icon to change just this transaction's category; the rest
            // of the row keeps its own tap (open detail). A Button nests cleanly
            // inside the row's enclosing Button/NavigationLink in a List.
            Button {
                showCategoryPicker = true
            } label: {
                ZStack {
                    Circle().fill(categoryColor.opacity(0.14))
                    Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(categoryColor)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change category")
            .accessibilityIdentifier("categoryIcon-\(transaction.id)")
            .sheet(isPresented: $showCategoryPicker) {
                // The category @Query lives in this host, which only exists while
                // the sheet is open — so scrolling rows never runs the query.
                CategoryPickerHost(transaction: transaction)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.payee ?? transaction.detail)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if isFee {
                        rowTag("FEE", color: .negative)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(transaction.category?.name ?? "Uncategorized") · \(transaction.posted.formatted(.dateTime.month().day()))")
                    if transaction.pending {
                        Text("· Pending").foregroundStyle(.orange)
                    }
                    if transaction.note != nil {
                        Image(systemName: "note.text")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            MoneyText(value: transaction.amount, code: transaction.account?.currency ?? "USD",
                      size: 15, weight: .semibold,
                      color: isFee ? .negative : amountColor(transaction.amount))
                .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 48 }
    }

    private func rowTag(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Hosts the category picker's @Query so it only runs while the sheet is open.
private struct CategoryPickerHost: View {
    let transaction: Transaction
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var rules: [CategoryRule]
    @Query private var allTransactions: [Transaction]
    @Environment(\.modelContext) private var context

    var body: some View {
        CategoryPickerSheet(
            categories: categories,
            selectedName: transaction.category?.name,
            isUncategorizedSelected: transaction.category == nil,
            merchant: CategorizationEngine.normalizeMerchant(transaction.payee ?? transaction.detail),
            suggestions: CategorizationEngine.suggestions(forMatchText: transaction.matchText,
                                                          rules: rules, transactions: allTransactions),
            onSelect: { CategorizationEngine.assign($0, to: transaction, in: context) }
        )
    }
}
