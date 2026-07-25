import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query private var budgets: [Budget]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var transactions: [Transaction]
    @State private var showingAdd = false
    @State private var editingBudget: Budget?

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
                        Section {
                            ForEach(budgets) { budget in
                                Button { editingBudget = budget } label: {
                                    BudgetRow(
                                        budget: budget,
                                        spent: budget.category.map {
                                            Analytics.spending(for: $0, in: transactions, inMonthOf: now, calendar: calendar)
                                        } ?? 0
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.surface)
                                .accessibilityIdentifier("budgetRow-\(budget.category?.name ?? "none")")
                            }
                            .onDelete(perform: delete)
                        } footer: {
                            if budgets.count > 6 {
                                Text("Only the first 6 budgets appear on the Dashboard card.")
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                    .listRowSeparatorTint(Color.hairline)
                    .screenBackground()
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
            .sheet(item: $editingBudget) { budget in
                EditBudgetView(budget: budget)
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
    private var ringColor: Color { over ? .negative : .brand }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.hairline, lineWidth: 6)
                Circle().trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: budget.category?.systemIcon ?? "tag")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: budget.category?.colorHex ?? "#8E8E93"))
                    Text(budget.category?.name ?? "—").foregroundStyle(Color.textPrimary)
                }
                HStack(spacing: 4) {
                    MoneyText(value: spent, size: 14, weight: .semibold,
                              color: over ? .negative : .textPrimary)
                    Text("of").font(.caption).foregroundStyle(Color.textSecondary)
                    MoneyText(value: budget.monthlyLimit, size: 14, weight: .regular, color: .textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
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
                Section {
                    Picker("Category", selection: $selected) {
                        Text("Select").tag(Category?.none)
                        ForEach(categories) { cat in
                            Text(cat.name).tag(Category?.some(cat))
                        }
                    }
                    TextField("Monthly limit", value: $amount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                }
                .listRowBackground(Color.surface)
            }
            .screenBackground()
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

/// Edit an existing budget's monthly limit. The category is fixed (it keys the
/// budget); to change it, delete this one and add another.
struct EditBudgetView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let budget: Budget

    @State private var amount: Decimal?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: budget.category?.systemIcon ?? "tag")
                            .foregroundStyle(Color(hex: budget.category?.colorHex ?? "#8E8E93"))
                        Text(budget.category?.name ?? "—")
                            .foregroundStyle(Color.textPrimary)
                    }
                    TextField("Monthly limit", value: $amount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("editBudgetLimitField")
                }
                .listRowBackground(Color.surface)
            }
            .screenBackground()
            .navigationTitle("Edit Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled((amount ?? 0) <= 0)
                }
            }
            .onAppear { amount = budget.monthlyLimit }
        }
    }

    private func save() {
        guard let amount, amount > 0 else { return }
        budget.monthlyLimit = amount
        try? context.save()
        dismiss()
    }
}
