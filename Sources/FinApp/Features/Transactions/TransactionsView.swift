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
                    ScrollViewReader { proxy in
                        List {
                            ListTopAnchor()
                            ForEach(monthGroups, id: \.month) { group in
                                Section {
                                    ForEach(group.txns) { txn in
                                        NavigationLink(value: txn) {
                                            TransactionRow(transaction: txn)
                                        }
                                        .listRowBackground(Color.surface)
                                        .accessibilityIdentifier("txnRow-\(txn.id)")
                                    }
                                } header: {
                                    Text(group.month.formatted(.dateTime.month(.wide).year()))
                                }
                            }
                        }
                        .listRowSeparatorTint(Color.hairline)
                        .screenBackground()
                        .onChange(of: router.selectedTab) {
                            if router.selectedTab == AppTab.transactions.rawValue {
                                proxy.scrollTo("listTop", anchor: .top)
                            }
                        }
                    }
                }
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle("Transactions")
                .navigationDestination(for: Transaction.self) { txn in
                    TransactionDetailView(transaction: txn)
                }
                .refreshable { await coordinator.sync() }
            }
        }
        .onChange(of: router.resetToken) { path = []; search = "" }
        .onChange(of: router.pendingTxnID) { openPendingTransaction() }
        .onChange(of: router.selectedTab) { handleTabChange() }
        .onChange(of: path) { handlePathChange() }
        .onAppear { openPendingTransaction() }
    }

    /// On arrival at the Transactions tab (tab tap or swipe), clear the filter and
    /// search — unless it was a deep-link that wants to keep its filter. On leaving,
    /// pop any pushed detail so the tab returns to its root.
    private func handleTabChange() {
        if router.selectedTab == AppTab.transactions.rawValue {
            if !router.txnArrivalIsDeepLink {
                router.txnFilter = .all
                search = ""
            }
            router.txnArrivalIsDeepLink = false
            router.subpageOpen = !path.isEmpty
        } else {
            path = []
        }
    }

    // Only the active tab owns `subpageOpen`, so an inactive tab resetting its path
    // can't re-enable pager swiping while this detail is open (which would let a
    // back-swipe page to a neighbouring tab instead of popping the detail).
    private func handlePathChange() {
        if router.selectedTab == AppTab.transactions.rawValue {
            router.subpageOpen = !path.isEmpty
        }
    }

    /// Transactions grouped by month, newest month first.
    private var monthGroups: [(month: Date, txns: [Transaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) {
            cal.dateInterval(of: .month, for: $0.posted)?.start ?? $0.posted
        }
        return grouped.map { (month: $0.key, txns: $0.value) }.sorted { $0.month > $1.month }
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
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
                .accessibilityIdentifier("txnSearchField")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func filterChip(_ label: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Filtered: \(label)")
                    .font(.system(size: 13, weight: .semibold))
                Button { router.txnFilter = .all } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.brand.opacity(0.12), in: Capsule())
            Spacer()
        }
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
            .listRowBackground(Color.surface)
            Section {
                LabeledContent("Amount") {
                    MoneyText(value: transaction.amount,
                              color: transaction.isInflow ? .positive : .textPrimary)
                }
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
            .listRowBackground(Color.surface)
            Section("Recurring") {
                if alreadyRecurring {
                    Label("Added to Recurring", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.positive)
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
            .listRowBackground(Color.surface)
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
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
