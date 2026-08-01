import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]
    @State private var search = ""
    @State private var showFilterSheet = false
    @State private var path = NavigationPath()
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
                    activeFilterChips
                    transactionList
                }
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle("Transactions")
                .fixLargeTitleInset(trigger: topReset)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFilterSheet = true } label: {
                            Image(systemName: router.txnFilter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                                .foregroundStyle(router.txnFilter.isActive ? Color.brand : Color.textPrimary)
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
                }
                .navigationDestination(for: Transaction.self) { txn in
                    TransactionDetailView(transaction: txn)
                }
                .navigationDestination(for: Account.self) { AccountDetailView(account: $0) }
            }
        }
        // The filter sheet presents above the app's privacy cover, so it would
        // stay in the app-switcher snapshot; dismiss when leaving foreground.
        .onChange(of: scenePhase) {
            if scenePhase != .active { showFilterSheet = false }
        }
        .onChange(of: router.resetToken) {
            path = NavigationPath()
            search = router.pendingSearch ?? ""
            router.pendingSearch = nil
        }
        .onChange(of: router.pendingTxnID) { openPendingTransaction() }
        .onChange(of: router.selectedTab) { handleTabChange() }
        .onChange(of: path.count) { handlePathChange() }
        .onAppear { openPendingTransaction() }
    }

    private func txnLink(_ txn: Transaction) -> some View {
        NavigationLink(value: txn) {
            TransactionRow(transaction: txn)
        }
        .listRowBackground(Color.surface)
        .accessibilityIdentifier("txnRow-\(txn.id)")
    }

    private var transactionList: some View {
        List {
            ForEach(monthGroups, id: \.month) { group in
                transactionSection(month: group.month, transactions: group.txns)
            }
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .id(topReset)
    }

    private func transactionSection(month: Date, transactions: [Transaction]) -> some View {
        Section {
            ForEach(transactions) { transaction in
                txnLink(transaction)
            }
        } header: {
            monthHeader((month: month, txns: transactions))
        }
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
            path = NavigationPath()
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
        path = NavigationPath()
        path.append(txn)
        router.pendingTxnID = nil
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.textTertiary)
            TextField("", text: $search,
                      prompt: Text("Search payee, category, or notes").foregroundStyle(Color.textTertiary))
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
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Active filter chips

    /// Removable chips for the active facets, under the search bar. Only shown
    /// when a filter is on; the combined popup (glass button) does the editing.
    @ViewBuilder
    private var activeFilterChips: some View {
        let filter = router.txnFilter
        if filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filter.categories.sorted { chipName($0) < chipName($1) }, id: \.self) { item in
                        activeChip(chipName(item)) {
                            var f = router.txnFilter
                            f.categories.remove(item)
                            router.txnFilter = f
                        }
                    }
                    if filter.type != .all {
                        activeChip(filter.type == .income ? "Income" : "Expenses") {
                            var f = router.txnFilter
                            f.type = .all
                            router.txnFilter = f
                        }
                    }
                    if let month = filter.month {
                        activeChip(month.formatted(.dateTime.month(.abbreviated).year())) {
                            var f = router.txnFilter
                            f.month = nil
                            router.txnFilter = f
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
        }
    }

    private func chipName(_ item: TransactionFilterState.CategoryFilterItem) -> String {
        switch item {
        case .uncategorized: "Uncategorized"
        case .named(let name): name
        }
    }

    private func activeChip(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.appBackground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.brand, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label) filter")
        .accessibilityIdentifier("facetChip-\(label)")
    }

    /// Uppercase month title plus that month's inflow/outflow subtotals over
    /// exactly the rows shown in the section.
    private func monthHeader(_ group: (month: Date, txns: [Transaction])) -> some View {
        let inflow = group.txns.filter { $0.amount > 0 }.reduce(Decimal(0)) { $0 + $1.amount }
        let outflow = group.txns.filter { $0.amount < 0 }.reduce(Decimal(0)) { $0 - $1.amount }
        let whole = Decimal.FormatStyle.Currency.currency(code: "USD").precision(.fractionLength(0))
        return HStack {
            Text(group.month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            // Subtotals only when a facet filter narrows the list; plain browsing
            // (or search-only) shows just the month name.
            if router.txnFilter.isActive {
                HStack(spacing: 4) {
                    if inflow > 0 {
                        Text("+\(inflow.formatted(whole))")
                            .foregroundStyle(Color.positive)
                    }
                    if inflow > 0 && outflow > 0 {
                        Text("·").foregroundStyle(Color.textTertiary)
                    }
                    if outflow > 0 {
                        Text("−\(outflow.formatted(whole))")
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .accessibilityIdentifier("monthSubtotal")
            }
        }
    }
}

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var recurringBills: [RecurringBill]
    @Query private var rules: [CategoryRule]
    @Query(sort: \Transaction.posted, order: .reverse) private var allTransactions: [Transaction]
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

    /// This merchant's charges, newest first, for the stats card.
    private var merchantCharges: [Transaction] {
        allTransactions.filter {
            CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail) == merchant
        }
    }

    private var categoryColor: Color { Color(hex: transaction.category?.colorHex ?? "#8E8E93") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                categoryMenu
                SectionLabel("Details").padding(.horizontal, 4)
                detailsCard
                SectionLabel("Note").padding(.horizontal, 4)
                noteCard
                SectionLabel("This merchant").padding(.horizontal, 4)
                merchantCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .keyboardAvoiding()
        .navigationTitle("Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { noteText = transaction.note ?? "" }
        .onChange(of: noteText) { applyNote() }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(categoryColor.opacity(0.14))
                Image(systemName: transaction.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(categoryColor)
            }
            .frame(width: 56, height: 56)
            Text(transaction.payee ?? transaction.detail)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            MoneyText(value: transaction.amount, code: transaction.account?.currency ?? "USD",
                      size: 34, weight: .bold, color: amountColor(transaction.amount))
            HStack(spacing: 6) {
                Text("\(transaction.posted.formatted(date: .abbreviated, time: .omitted))\(transaction.account.map { " · \($0.displayName)" } ?? "")")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                if transaction.pending {
                    Text("PENDING")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow("Description", transaction.detail)
            if let payee = transaction.payee {
                Divider().overlay(Color.hairline)
                detailRow("Payee", payee)
            }
            if let account = transaction.account {
                Divider().overlay(Color.hairline)
                NavigationLink(value: account) {
                    HStack {
                        Text("Account")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textSecondary)
                        Spacer()
                        Text(account.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.brand)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private var noteCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: 14))
                .foregroundStyle(Color.textTertiary)
            TextField("", text: $noteText,
                      prompt: Text("Add a note…").foregroundStyle(Color.textTertiary),
                      axis: .vertical)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("txnNoteField")
                // Keeps the field above the keyboard: the pager disables the
                // keyboard safe area (RootView), which also kills SwiftUI's
                // focus scroll. Pair with keyboardAvoiding() above.
                .background(KeyboardReveal())
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var merchantCard: some View {
        VStack(spacing: 0) {
            if let stats = Analytics.merchantYearStats(merchantCharges, inYearOf: transaction.posted) {
                Button { router.showTransactions(searching: merchant) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(stats.visits) \(stats.visits == 1 ? "visit" : "visits") this year")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("\(Money.string(stats.total)) total · avg \(Money.string(stats.average))")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        merchantBars
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("merchantStatsRow")
                Divider().overlay(Color.hairline)
            }
            recurringRow
        }
        .padding(.horizontal, 16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    /// Tiny bar per recent charge; the open transaction's bar is brand.
    private var merchantBars: some View {
        let recent = Array(merchantCharges.prefix(6).reversed())
        let maxMag = recent.map { abs($0.amount) }.max() ?? 1
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(recent, id: \.id) { charge in
                let fraction = maxMag > 0
                    ? (abs(charge.amount) / maxMag as NSDecimalNumber).doubleValue : 0
                Capsule()
                    .fill(charge.id == transaction.id ? Color.brand : Color.hairline)
                    .frame(width: 4, height: max(4, 18 * fraction))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var recurringRow: some View {
        if alreadyRecurring {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.positive)
                Text("Added to Recurring")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }
            .padding(.vertical, 13)
            .accessibilityIdentifier("recurringAddedIndicator")
        } else {
            HStack(spacing: 10) {
                Button {
                    setRecurring()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.brand.opacity(0.12))
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brand)
                        }
                        .frame(width: 30, height: 30)
                        Text("Set as recurring")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Set as Recurring")
                Menu {
                    Picker("Cadence", selection: $recurringCadence) {
                        ForEach(Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.rawValue.capitalized).tag(cadence)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(recurringCadence.rawValue.capitalized)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.surfaceElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
                }
                .accessibilityIdentifier("recurringCadenceMenu")
            }
            .padding(.vertical, 10)
        }
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
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(
                categories: categories,
                selectedName: transaction.category?.name,
                isUncategorizedSelected: transaction.category == nil,
                merchant: merchant,
                suggestions: CategorizationEngine.suggestions(forMatchText: transaction.matchText,
                                                              rules: rules, transactions: allTransactions),
                onSelect: { CategorizationEngine.assign($0, to: transaction, in: context) }
            )
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
