import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppRouter.self) private var router
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @State private var search = ""
    @State private var path: [Transaction] = []

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
        case .uncategorized: txn.category == nil
        case .category(let name): txn.category?.name == name
        }
    }

    private var filterLabel: String? {
        switch router.txnFilter {
        case .all: nil
        case .income: "Income"
        case .spending: "Spending"
        case .uncategorized: "Uncategorized"
        case .category(let name): name
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                            NavigationLink(value: txn) {
                                TransactionRow(transaction: txn)
                            }
                            .accessibilityIdentifier("txnRow-\(txn.id)")
                        }
                    }
                }
                .navigationTitle("Transactions")
                .navigationDestination(for: Transaction.self) { txn in
                    TransactionDetailView(transaction: txn)
                }
                .refreshable { await coordinator.sync() }
            }
        }
        .onChange(of: router.resetToken) { path = [] }
        .onChange(of: router.pendingTxnID) { openPendingTransaction() }
        .onAppear { openPendingTransaction() }
    }

    /// Honor a request (from Dashboard/Accounts) to open a specific transaction.
    private func openPendingTransaction() {
        guard let id = router.pendingTxnID,
              let txn = transactions.first(where: { $0.id == id }) else { return }
        path = [txn]
        router.pendingTxnID = nil
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
    @Query private var recurringBills: [RecurringBill]
    let transaction: Transaction

    @State private var recurringCadence: Cadence = .monthly

    private var merchant: String {
        CategorizationEngine.normalizeMerchant(transaction.payee ?? transaction.detail)
    }

    private var alreadyRecurring: Bool {
        recurringBills.contains { $0.merchantName == merchant && $0.confirmed && !$0.dismissed }
    }

    var body: some View {
        List {
            Section {
                categoryMenu
            }
            Section {
                LabeledContent("Amount", value: Money.string(transaction.amount))
                LabeledContent("Date", value: transaction.posted.formatted(date: .abbreviated, time: .omitted))
                if let account = transaction.account {
                    LabeledContent("Account", value: account.displayName)
                }
                LabeledContent("Description", value: transaction.detail)
                if let payee = transaction.payee {
                    LabeledContent("Payee", value: payee)
                }
                if transaction.pending {
                    LabeledContent("Status", value: "Pending")
                }
            }
            Section("Recurring") {
                if alreadyRecurring {
                    Label("Added to Recurring", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("recurringAddedIndicator")
                } else {
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
        }
        .navigationTitle(transaction.payee ?? transaction.detail)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(categories) { category in
                Button {
                    // Remember this choice as a rule (applies to future syncs) and
                    // apply it now to similar existing transactions.
                    CategorizationEngine.learn(from: transaction, category: category, in: context)
                    CategorizationEngine.categorizeAll(in: context)
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
        RecurringStore.setRecurring(
            merchant: merchant,
            amount: abs(transaction.amount),
            cadence: recurringCadence,
            lastSeen: transaction.posted,
            category: transaction.category,
            in: context
        )
    }
}
