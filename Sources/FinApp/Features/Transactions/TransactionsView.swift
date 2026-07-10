import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]
    @State private var search = ""
    @State private var showFilterSheet = false
    @State private var path: [Transaction] = []
    /// Bumped on tab arrival to rebuild the List at the very top.
    @State private var topReset = 0

    private var filtered: [Transaction] {
        let filter = router.txnFilter
        let interval = filter.month.flatMap { Calendar.current.dateInterval(of: .month, for: $0) }
        var result = transactions.filter { filter.matches($0, monthInterval: interval) }
        if !search.isEmpty {
            // Case-insensitive range search avoids allocating a lowercased copy
            // of every payee on every keystroke.
            result = result.filter {
                ($0.payee ?? $0.detail).range(of: search, options: .caseInsensitive) != nil
                || ($0.category?.name.range(of: search, options: .caseInsensitive) != nil)
                || ($0.note?.range(of: search, options: .caseInsensitive) != nil)
            }
        }
        return result
    }

    /// Facet summaries joined with "·". A single category renders as just its
    /// name (e.g. "Filtered: Housing") — UI tests assert those exact strings.
    private var filterLabel: String? {
        let filter = router.txnFilter
        guard filter.isActive else { return nil }
        var parts: [String] = []
        if filter.categories.count == 1, let item = filter.categories.first {
            switch item {
            case .uncategorized: parts.append("Uncategorized")
            case .named(let name): parts.append(name)
            }
        } else if filter.categories.count > 1 {
            parts.append("\(filter.categories.count) categories")
        }
        switch filter.type {
        case .all: break
        case .income: parts.append("Income")
        case .spending: parts.append("Expenses")
        }
        if let month = filter.month {
            parts.append(month.formatted(.dateTime.month(.abbreviated).year()))
        }
        return parts.joined(separator: " · ")
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
                    .id(topReset)
                }
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle("Transactions")
                .fixLargeTitleInset(trigger: topReset)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: router.txnFilter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Filter transactions")
                        .accessibilityIdentifier("filterButton")
                    }
                }
                .sheet(isPresented: $showFilterSheet) {
                    TransactionFilterSheet(
                        filter: Binding(get: { router.txnFilter }, set: { router.txnFilter = $0 }),
                        categories: categories,
                        months: availableMonths
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .navigationDestination(for: Transaction.self) { txn in
                    TransactionDetailView(transaction: txn)
                }
            }
        }
        // The sheet presents above the app's privacy cover, so it would stay
        // visible in the app-switcher snapshot; dismiss when leaving foreground.
        .onChange(of: scenePhase) { if scenePhase != .active { showFilterSheet = false } }
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
                router.txnFilter = TransactionFilterState()
                search = ""
            }
            router.txnArrivalIsDeepLink = false
            router.subpageOpen = !path.isEmpty
            topReset += 1   // arriving → rebuild the list at the very top
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

    /// Distinct month-starts with at least one transaction, newest first —
    /// computed over ALL transactions (not `filtered`) so the sheet's month
    /// stepper isn't narrowed by the other active facets. Same linear-pass
    /// trick as `monthGroups`: the query is already posted-descending.
    private var availableMonths: [Date] {
        let cal = Calendar.current
        var months: [Date] = []
        for txn in transactions {
            let month = cal.dateInterval(of: .month, for: txn.posted)?.start ?? txn.posted
            if months.last != month { months.append(month) }
        }
        return months
    }

    /// Transactions grouped by month, newest month first. `filtered` preserves the
    /// query's posted-descending order, so groups build in one linear pass —
    /// no dictionary or re-sort.
    private var monthGroups: [(month: Date, txns: [Transaction])] {
        let cal = Calendar.current
        var groups: [(month: Date, txns: [Transaction])] = []
        for txn in filtered {
            let month = cal.dateInterval(of: .month, for: txn.posted)?.start ?? txn.posted
            if groups.last?.month == month {
                groups[groups.count - 1].txns.append(txn)
            } else {
                groups.append((month: month, txns: [txn]))
            }
        }
        return groups
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
            TextField("Search payee, category, or notes", text: $search)
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
                .accessibilityLabel("Clear search")
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
                Button { router.txnFilter = TransactionFilterState() } label: {
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
    @State private var showCategoryPicker = false
    @State private var noteText = ""

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
                              color: balanceColor(transaction.amount))
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
            Section("Note") {
                TextField("Add a note", text: $noteText, axis: .vertical)
                    .accessibilityIdentifier("txnNoteField")
                    // Keeps the field above the keyboard: the pager disables the
                    // keyboard safe area (RootView), which also kills SwiftUI's
                    // focus scroll, and ScrollViewReader.scrollTo is a no-op in
                    // this List. Pair with keyboardAvoiding() below.
                    .background(KeyboardReveal())
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
                    .tint(Color.textPrimary)
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
        .keyboardAvoiding()
        .navigationTitle(transaction.payee ?? transaction.detail)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { noteText = transaction.note ?? "" }
        .onChange(of: noteText) { applyNote() }
    }

    /// Persist the edited note (blank clears it), mirroring the account-rename
    /// pattern; sync never writes `note`, so it survives re-syncs.
    private func applyNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.note = trimmed.isEmpty ? nil : trimmed
        try? context.save()
    }

    private var categoryMenu: some View {
        Button {
            showCategoryPicker = true
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("categoryMenu")
        .popover(isPresented: $showCategoryPicker) {
            CategoryPickerPopup(
                categories: categories,
                selectedName: transaction.category?.name,
                isUncategorizedSelected: transaction.category == nil,
                onSelect: { CategorizationEngine.assign($0, to: transaction, in: context) }
            )
            .presentationCompactAdaptation(.popover)
        }
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
