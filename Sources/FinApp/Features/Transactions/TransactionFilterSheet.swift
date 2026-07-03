import SwiftUI

/// Multi-facet filter sheet for the Transactions list: month, flow type, and
/// categories (multi-select). Every toggle writes straight back through the
/// binding so the list live-updates behind the medium detent; "Done" just
/// dismisses.
struct TransactionFilterSheet: View {
    @Binding var filter: TransactionFilterState
    let categories: [Category]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Month") {
                    monthRow
                }
                .listRowBackground(Color.surface)

                Section("Type") {
                    Picker("Type", selection: $filter.type) {
                        Text("All").tag(TransactionFilterState.FlowType.all)
                        Text("Income").tag(TransactionFilterState.FlowType.income)
                        Text("Expenses").tag(TransactionFilterState.FlowType.spending)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("typeFilterPicker")
                }
                .listRowBackground(Color.surface)

                Section("Categories") {
                    toggleRow(name: "Uncategorized", icon: "questionmark.circle",
                              color: Color.textSecondary, item: .uncategorized)
                        .accessibilityIdentifier("txnCatToggle-Uncategorized")
                    ForEach(categories) { category in
                        toggleRow(name: category.name, icon: category.systemIcon,
                                  color: Color(hex: category.colorHex),
                                  item: .named(category.name))
                            .accessibilityIdentifier("txnCatToggle-\(category.name)")
                    }
                }
                .listRowBackground(Color.surface)
            }
            .listRowSeparatorTint(Color.hairline)
            .screenBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear All") { filter = TransactionFilterState() }
                        .disabled(!filter.isActive)
                        .accessibilityIdentifier("filterClearAll")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("filterDone")
                }
            }
        }
    }

    private var monthRow: some View {
        HStack {
            Button { step(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brand)
            .accessibilityLabel("Previous month")
            .accessibilityIdentifier("filterMonthBack")

            Text(filter.month?.formatted(.dateTime.month(.wide).year()) ?? "All time")
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("filterMonthLabel")

            Button { step(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brand)
            .accessibilityLabel("Next month")
            .accessibilityIdentifier("filterMonthForward")

            if filter.month != nil {
                Button("All time") { filter.month = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .accessibilityIdentifier("filterMonthAllTime")
            }
        }
    }

    /// From "All time", a chevron tap seeds the current month; otherwise steps.
    private func step(by value: Int) {
        let cal = Calendar.current
        let current = filter.month ?? cal.dateInterval(of: .month, for: .now)?.start ?? .now
        let base = filter.month == nil ? current : cal.date(byAdding: .month, value: value, to: current) ?? current
        filter.month = cal.dateInterval(of: .month, for: base)?.start ?? base
    }

    private func toggleRow(name: String, icon: String, color: Color,
                           item: TransactionFilterState.CategoryFilterItem) -> some View {
        let selected = filter.categories.contains(item)
        return Button {
            if selected { filter.categories.remove(item) } else { filter.categories.insert(item) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .frame(width: 22)
                Text(name)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 16)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.brand : Color.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
