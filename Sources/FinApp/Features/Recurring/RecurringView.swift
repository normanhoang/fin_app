import SwiftUI
import SwiftData

struct RecurringView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \RecurringBill.nextDue) private var bills: [RecurringBill]
    @State private var path: [RecurringBill] = []
    /// Bumped on tab arrival to rebuild the List at the very top.
    @State private var topReset = 0

    private var confirmed: [RecurringBill] { bills.filter { $0.confirmed && !$0.dismissed } }
    private var candidates: [RecurringBill] { bills.filter { !$0.confirmed && !$0.dismissed } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if confirmed.isEmpty && candidates.isEmpty {
                    ContentUnavailableView(
                        "No Recurring Bills",
                        systemImage: "arrow.clockwise",
                        description: Text("Subscriptions and bills are detected automatically as you sync.")
                    )
                } else {
                    List {
                        if !confirmed.isEmpty {
                            Section {
                                ForEach(confirmed) { billRow($0) }
                            } header: {
                                Text("Upcoming")
                            }
                            .listRowBackground(Color.surface)
                        }
                        if !candidates.isEmpty {
                            Section {
                                ForEach(candidates) { billRow($0) }
                            } header: {
                                Text("Detected")
                            } footer: {
                                Text("Tap a detected bill to confirm it or remove a false match.")
                            }
                            .listRowBackground(Color.surface)
                        }
                    }
                    .listRowSeparatorTint(Color.hairline)
                    .screenBackground()
                    .id(topReset)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Recurring")
            .navigationDestination(for: RecurringBill.self) { RecurringDetailView(bill: $0) }
        }
        .onChange(of: router.selectedTab) {
            if router.selectedTab == AppTab.recurring.rawValue {
                router.subpageOpen = !path.isEmpty
                topReset += 1
            } else { path = [] }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.recurring.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    private func billRow(_ bill: RecurringBill) -> some View {
        NavigationLink(value: bill) {
            RecurringRow(bill: bill)
        }
        .accessibilityIdentifier("recurringRow-\(bill.merchantName)")
    }
}

struct RecurringRow: View {
    let bill: RecurringBill

    private var dueText: String? {
        bill.nextDue.map { "next \($0.formatted(.dateTime.month().day()))" }
    }

    var body: some View {
        let color = Color(hex: bill.category?.colorHex ?? "#8E8E93")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(bill.merchantName.capitalized).foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Chip(bill.cadence.rawValue.capitalized, color: .brand)
                    if let dueText {
                        Text(dueText).font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
            }
            Spacer()
            MoneyText(value: bill.expectedAmount, size: 16, weight: .semibold, color: .textSecondary)
        }
        .padding(.vertical, 2)
    }
}

/// Past charges for one recurring bill, with the ability to recategorize it.
struct RecurringDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Query(sort: \Transaction.posted, order: .reverse) private var allTransactions: [Transaction]
    @Bindable var bill: RecurringBill
    @State private var amountText = ""
    @State private var showingCategoryPicker = false

    private var matched: [Transaction] {
        allTransactions.filter {
            CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail) == bill.merchantName
        }
    }

    private var monthGroups: [(month: Date, txns: [Transaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: matched) {
            cal.dateInterval(of: .month, for: $0.posted)?.start ?? $0.posted
        }
        return grouped.map { (month: $0.key, txns: $0.value) }.sorted { $0.month > $1.month }
    }

    var body: some View {
        List {
            Section {
                categoryMenu
                Picker("Cadence", selection: $bill.cadence) {
                    ForEach(Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.rawValue.capitalized).tag(cadence)
                    }
                }
                LabeledContent("Typical amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("recurringAmountField")
                }
                if !bill.confirmed {
                    Button {
                        bill.confirmed = true
                        try? context.save()
                    } label: {
                        Label("Confirm Recurring", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("confirmRecurringButton")
                }
                Button(role: .destructive) {
                    bill.dismissed = true
                    try? context.save()
                    dismiss()
                } label: {
                    Label("Delete Recurring", systemImage: "trash")
                }
                .accessibilityIdentifier("deleteRecurringButton")
            }
            .listRowBackground(Color.surface)

            if matched.isEmpty {
                Section("Past charges") {
                    Text("No past charges found for this merchant.")
                        .foregroundStyle(Color.textSecondary)
                }
                .listRowBackground(Color.surface)
            } else {
                ForEach(monthGroups, id: \.month) { group in
                    Section {
                        ForEach(group.txns) { txn in
                            TransactionRow(transaction: txn)
                                .contentShape(Rectangle())
                                .onTapGesture { router.openTransaction(id: txn.id) }
                                .accessibilityIdentifier("recurringTxnRow-\(txn.id)")
                        }
                    } header: {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                    }
                    .listRowBackground(Color.surface)
                }
            }
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .navigationTitle(bill.merchantName.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { amountText = NSDecimalNumber(decimal: bill.expectedAmount).stringValue }
        .onChange(of: amountText) { applyAmount() }
        .onChange(of: bill.cadenceRaw) { try? context.save() }
    }

    /// Persist an edited typical amount (ignores unparseable input).
    private func applyAmount() {
        guard let value = Decimal(string: amountText, locale: .current) else { return }
        bill.expectedAmount = value
        try? context.save()
    }

    private var categoryMenu: some View {
        Button { showingCategoryPicker = true } label: {
            HStack {
                Label {
                    Text(bill.category?.name ?? "Uncategorized").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                        .foregroundStyle(Color(hex: bill.category?.colorHex ?? "#8E8E93"))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recurringCategoryMenu")
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPicker(current: bill.category) { selected in
                if let selected { setCategory(selected) }
            }
        }
    }

    /// Set the bill's category and apply it to this merchant's transactions, learning
    /// a rule so future charges categorize automatically.
    private func setCategory(_ category: Category) {
        bill.category = category
        if let sample = matched.first {
            CategorizationEngine.learn(from: sample, category: category, in: context)
        }
        CategorizationEngine.categorizeAll(in: context)
        try? context.save()
    }
}
