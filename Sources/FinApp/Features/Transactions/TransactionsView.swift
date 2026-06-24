import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppRouter.self) private var router
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @State private var search = ""

    private var filtered: [Transaction] {
        var result = transactions.filter { matches(router.txnFilter, $0) }
        if !search.isEmpty {
            let needle = search.lowercased()
            result = result.filter {
                ($0.payee ?? $0.detail).lowercased().contains(needle)
                || ($0.category?.name.lowercased().contains(needle) ?? false)
            }
        }
        return result
    }

    private func matches(_ filter: TransactionFilter, _ txn: Transaction) -> Bool {
        switch filter {
        case .all: true
        case .income: txn.category?.isIncome == true && txn.amount > 0
        case .spending: txn.amount < 0 && txn.category?.isIncome != true
        case .category(let name): txn.category?.name == name
        }
    }

    private var filterLabel: String? {
        switch router.txnFilter {
        case .all: nil
        case .income: "Income"
        case .spending: "Spending"
        case .category(let name): name
        }
    }

    var body: some View {
        NavigationStack {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "list.bullet",
                    description: Text("Transactions appear here once you connect SimpleFin.")
                )
                .navigationTitle("Transactions")
            } else {
                VStack(spacing: 0) {
                    searchBar
                    if let label = filterLabel {
                        filterChip(label)
                    }
                    List {
                        ForEach(filtered) { txn in
                            NavigationLink {
                                TransactionDetailView(transaction: txn)
                            } label: {
                                TransactionRow(transaction: txn)
                            }
                            .accessibilityIdentifier("txnRow-\(txn.id)")
                        }
                    }
                }
                .navigationTitle("Transactions")
                .refreshable { await coordinator.sync() }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search payee or category", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityIdentifier("txnSearchField")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func filterChip(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text("Filtered: \(label)").font(.subheadline)
            Button {
                router.txnFilter = .all
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.name) private var categories: [Category]
    let transaction: Transaction

    @State private var recurringCadence: Cadence = .monthly

    var body: some View {
        List {
            Section {
                categoryMenu
            }
            Section {
                LabeledContent("Amount", value: Money.string(transaction.amount))
                LabeledContent("Date", value: transaction.posted.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Description", value: transaction.detail)
                if let payee = transaction.payee {
                    LabeledContent("Payee", value: payee)
                }
                if transaction.pending {
                    LabeledContent("Status", value: "Pending")
                }
            }
            Section("Recurring") {
                Picker("Cadence", selection: $recurringCadence) {
                    ForEach(Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.rawValue.capitalized).tag(cadence)
                    }
                }
                Button {
                    setRecurring()
                } label: {
                    Label("Set as Recurring", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle(transaction.payee ?? transaction.detail)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(categories) { category in
                Button {
                    CategorizationEngine.learn(from: transaction, category: category, in: context)
                } label: {
                    Label(category.name, systemImage: category.systemIcon)
                    if transaction.category == category {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack {
                Label {
                    Text(transaction.category?.name ?? "Uncategorized").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                        .foregroundStyle(Color(hex: transaction.category?.colorHex ?? "#8E8E93"))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("categoryMenu")
    }

    private func setRecurring() {
        let calendar = Calendar.current
        let merchant = CategorizationEngine.normalizeMerchant(transaction.payee ?? transaction.detail)
        let nextDue = calendar.date(byAdding: .day, value: recurringCadence.days, to: transaction.posted)
        let bill = RecurringBill(
            merchantName: merchant,
            expectedAmount: abs(transaction.amount),
            cadence: recurringCadence,
            lastSeen: transaction.posted,
            nextDue: nextDue,
            confirmed: true,
            category: transaction.category
        )
        context.insert(bill)
        try? context.save()
    }
}
