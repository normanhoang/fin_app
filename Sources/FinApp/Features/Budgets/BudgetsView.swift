import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query private var budgets: [Budget]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var transactions: [Transaction]
    @State private var showingAdd = false

    private var now: Date { Date() }
    private var calendar: Calendar { .current }

    private var budgetedCategoryNames: Set<String> {
        Set(budgets.compactMap { $0.category?.name })
    }

    private var availableCategories: [Category] {
        categories.filter { !$0.isIncome && !budgetedCategoryNames.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if budgets.isEmpty {
                    ContentUnavailableView {
                        Label("No Budgets", systemImage: "chart.bar")
                    } description: {
                        Text("Set a monthly limit per category to track spending.")
                    } actions: {
                        Button("Add Budget") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(budgets) { budget in
                            BudgetRow(
                                budget: budget,
                                spent: budget.category.map {
                                    Analytics.spending(for: $0, in: transactions, inMonthOf: now, calendar: calendar)
                                } ?? 0
                            )
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .disabled(availableCategories.isEmpty)
            }
            .sheet(isPresented: $showingAdd) {
                AddBudgetView(categories: availableCategories)
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(budgets[i]) }
        try? context.save()
    }
}

struct BudgetRow: View {
    let budget: Budget
    let spent: Decimal

    private var fraction: Double {
        let limit = (budget.monthlyLimit as NSDecimalNumber).doubleValue
        guard limit > 0 else { return 0 }
        return min((spent as NSDecimalNumber).doubleValue / limit, 1)
    }

    private var over: Bool { spent > budget.monthlyLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(budget.category?.name ?? "—")
                } icon: {
                    Image(systemName: budget.category?.systemIcon ?? "tag")
                        .foregroundStyle(Color(hex: budget.category?.colorHex ?? "#8E8E93"))
                }
                Spacer()
                Text("\(Money.string(spent)) / \(Money.string(budget.monthlyLimit))")
                    .font(.subheadline)
                    .foregroundStyle(over ? .red : .secondary)
            }
            ProgressView(value: fraction)
                .tint(over ? .red : .green)
        }
        .padding(.vertical, 4)
    }
}

struct AddBudgetView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let categories: [Category]

    @State private var selected: Category?
    @State private var amount: Decimal?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $selected) {
                    Text("Select").tag(Category?.none)
                    ForEach(categories) { cat in
                        Text(cat.name).tag(Category?.some(cat))
                    }
                }
                TextField("Monthly limit", value: $amount, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(selected == nil || (amount ?? 0) <= 0)
                }
            }
        }
    }

    private func save() {
        guard let selected, let amount, amount > 0 else { return }
        context.insert(Budget(monthlyLimit: amount, category: selected))
        try? context.save()
        dismiss()
    }
}
