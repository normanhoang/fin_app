import SwiftUI
import SwiftData

/// Row order within each type group.
enum AccountSortMode: String, CaseIterable, Identifiable {
    case balance, name, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .balance: "Balance"
        case .name: "Name"
        case .custom: "Custom"
        }
    }
}

struct AccountsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var showingAdd = false
    @State private var path = NavigationPath()
    /// Bumped on tab arrival to rebuild the List at the very top.
    @State private var topReset = 0
    /// Type groups the user has collapsed; empty = all expanded (default).
    @State private var collapsedTypes: Set<AccountType> = []
    /// Row order within each type group, persisted across launches.
    @AppStorage("accountsSortMode") private var sortModeRaw = AccountSortMode.balance.rawValue

    private var sortMode: AccountSortMode {
        // Custom sort is retired from the menu; treat any persisted value as Balance.
        get {
            let mode = AccountSortMode(rawValue: sortModeRaw) ?? .balance
            return mode == .custom ? .balance : mode
        }
        nonmutating set { sortModeRaw = newValue.rawValue }
    }

    /// Accounts of one type, kept together as a subsection.
    private struct TypeGroup: Identifiable {
        let type: AccountType
        let accounts: [Account]
        var id: String { type.rawValue }
        var subtotal: Decimal { accounts.reduce(Decimal(0)) { $0 + $1.balance } }
    }

    private func groups(debt: Bool) -> [TypeGroup] {
        Dictionary(grouping: accounts.filter { $0.accountType.isDebt == debt }, by: \.accountType)
            .map { type, accts in
                TypeGroup(type: type, accounts: accts.sorted {
                    switch sortMode {
                    case .balance where $0.balance.magnitude != $1.balance.magnitude:
                        return $0.balance.magnitude > $1.balance.magnitude
                    case .custom where $0.customSortIndex != $1.customSortIndex:
                        return $0.customSortIndex < $1.customSortIndex
                    default:
                        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                })
            }
            .sorted { $0.type.sortIndex < $1.type.sortIndex }
    }

    private var assetGroups: [TypeGroup] { groups(debt: false) }
    private var debtGroups: [TypeGroup] { groups(debt: true) }
    private var allTypes: Set<AccountType> { Set((assetGroups + debtGroups).map(\.type)) }
    /// Superset, not equality: `collapsedTypes` can hold stale types (e.g. after an
    /// account is retyped), which would otherwise make collapse-all a visual no-op.
    private var allCollapsed: Bool { collapsedTypes.isSuperset(of: allTypes) }
    private func total(_ groups: [TypeGroup]) -> Decimal { groups.reduce(Decimal(0)) { $0 + $1.subtotal } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "building.columns")
                    } description: {
                        Text("Connect SimpleFin or add a manual account with the + button.")
                    } actions: {
                        Link("SimpleFin Setup Guide",
                             destination: URL(string: "https://normanhoang.github.io/fin_app/simplefin-setup")!)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.brand)
                            .accessibilityIdentifier("simplefinSetupLink")
                    }
                } else {
                    List {
                        netWorthSection
                        // One Section per type so the inset card rounds at each type's
                        // top and bottom. The Assets/Liabilities eyebrows get their own
                        // header-only Sections so the List's section spacing applies
                        // uniformly — eyebrow-to-type and type-to-type gaps match,
                        // expanded or collapsed.
                        if !assetGroups.isEmpty {
                            eyebrowSection("Assets", total: total(assetGroups))
                            ForEach(assetGroups) { typeSection($0) }
                        }
                        if !debtGroups.isEmpty {
                            eyebrowSection("Liabilities", total: total(debtGroups))
                            ForEach(debtGroups) { typeSection($0) }
                        }
                        syncFooterSection
                    }
                    .listRowSeparatorTint(Color.hairline)
                    .screenBackground()
                    .id(topReset)
                    .animation(.easeInOut(duration: 0.25), value: collapsedTypes)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Accounts")
            .fixLargeTitleInset(trigger: topReset)
            .navigationDestination(for: Account.self) { AccountDetailView(account: $0) }
            .navigationDestination(for: Transaction.self) { TransactionDetailView(transaction: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.brand)
                            Text("Add")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                        }
                    }
                    .accessibilityLabel("Add account")
                    .accessibilityIdentifier("addAccountButton")
                }
                if #available(iOS 26.0, *) {
                    // Split each control into its own glass pill instead of
                    // sharing one capsule.
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: Binding(
                            get: { sortMode },
                            set: { sortModeRaw = $0.rawValue }
                        )) {
                            ForEach(AccountSortMode.allCases.filter { $0 != .custom }) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Divider()
                        Button(allCollapsed ? "Expand All" : "Collapse All") {
                            collapsedTypes = allCollapsed ? [] : allTypes
                        }
                        .accessibilityIdentifier("accountCollapseAllToggle")
                    } label: {
                        HStack(spacing: 3) {
                            Text(sortMode.label)
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.textPrimary)
                    }
                    .accessibilityIdentifier("accountSortMenu")
                }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
        }
        .onChange(of: router.selectedTab) {
            if router.selectedTab == AppTab.accounts.rawValue {
                router.subpageOpen = !path.isEmpty
                topReset += 1
            } else { path = NavigationPath() }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.accounts.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    // MARK: Net-worth summary

    private var netWorthSection: some View {
        Section {
            netWorthCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var netWorthCard: some View {
        let assets = total(assetGroups)
        let liabilities = -total(debtGroups) // positive magnitude
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Net worth")
            MoneyText(value: assets - liabilities, size: 30, weight: .bold,
                      color: balanceColor(assets - liabilities))
            if assets > 0 || liabilities > 0 {
                splitBar(assets: assets, liabilities: liabilities)
                    .accessibilityHidden(true)
                HStack(spacing: 12) {
                    legend(color: .brand, label: "Assets", value: assets)
                    Spacer()
                    legend(color: .negative, label: "Liabilities", value: liabilities)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    LinearGradient(colors: [.brand.opacity(0.10), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("accountsNetWorthCard")
    }

    /// 6pt bar split brand/negative in proportion to assets vs |liabilities|.
    /// One continuous pill: segments butt together and the whole bar is clipped to
    /// a single capsule so it reads as one pill, not two.
    private func splitBar(assets: Decimal, liabilities: Decimal) -> some View {
        GeometryReader { geo in
            let a = (assets as NSDecimalNumber).doubleValue
            let l = (liabilities as NSDecimalNumber).doubleValue
            let magnitude = max(a, 0) + max(l, 0)
            if magnitude > 0 {
                HStack(spacing: 0) {
                    if a > 0 {
                        Color.brand
                            .frame(width: max(4, geo.size.width * a / magnitude))
                    }
                    if l > 0 {
                        Color.negative
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }

    private func legend(color: Color, label: String, value: Decimal) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text("\(label) \(Money.string(value))")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: Sections

    private func eyebrowSection(_ title: String, total: Decimal) -> some View {
        Section {
        } header: {
            HStack {
                SectionLabel(title)
                    .accessibilityLabel(title)
                Spacer()
                MoneyText(value: total, size: 13, weight: .semibold,
                          color: balanceColor(total))
            }
            .padding(.top, 4)
            .textCase(nil)
        }
    }

    private func typeSection(_ group: TypeGroup) -> some View {
        Section {
            if !collapsedTypes.contains(group.type) {
                ForEach(group.accounts) { account in
                    NavigationLink(value: account) {
                        row(account)
                    }
                    .listRowBackground(Color.surface)
                    // Separator starts after the icon column (36pt icon + 12pt gap).
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 48 }
                    .accessibilityIdentifier("accountRow-\(account.id)")
                }
                // Long-press drag to rearrange, only in Custom sort mode.
                .onMove(perform: sortMode == .custom ? { from, to in
                    move(in: group, from: from, to: to)
                } : nil)
            }
        } header: {
            HStack {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .rotationEffect(.degrees(collapsedTypes.contains(group.type) ? -90 : 0))
                Text(group.type.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                MoneyText(value: group.subtotal, size: 14, weight: .semibold,
                          color: balanceColor(group.subtotal))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if collapsedTypes.contains(group.type) {
                    collapsedTypes.remove(group.type)
                } else {
                    collapsedTypes.insert(group.type)
                }
            }
            .accessibilityIdentifier("accountGroupHeader-\(group.type.rawValue)")
            .textCase(nil)
        }
    }

    // MARK: Rows

    /// Tint for the row's icon circle: investments brand, cash sky blue,
    /// debts red, property gold.
    private func roleColor(_ type: AccountType) -> Color {
        switch type {
        case .investment: .brand
        case .cash: Color(hex: "#38BDF8")
        case .creditCard, .loan: .negative
        case .property: Color(hex: "#C4A46A")
        case .other: .textSecondary
        }
    }

    private func row(_ account: Account) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(roleColor(account.accountType).opacity(0.10))
                Image(systemName: account.accountType.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(roleColor(account.accountType))
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(metaLine(account))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            MoneyText(value: account.balance, code: account.currency, size: 15.5, weight: .semibold,
                      color: balanceColor(account.balance))
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.vertical, 4)
    }

    /// Account type, plus a "manual" tag for local accounts. Per-account sync time
    /// is dropped from the row; the overall "synced" stamp lives in the footer.
    private func metaLine(_ account: Account) -> String {
        let type = account.accountType.displayName
        return account.isManual ? "\(type) · manual" : type
    }

    /// Persist a Custom-mode drag: rewrite the group's order indexes.
    private func move(in group: TypeGroup, from source: IndexSet, to destination: Int) {
        var reordered = group.accounts
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, account) in reordered.enumerated() {
            account.customSortIndex = index
        }
        try? context.save()
    }

    // MARK: Sync footer

    private var syncFooterSection: some View {
        Section {
        } footer: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                Text(syncFooterText)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    private var syncFooterText: String {
        guard let last = coordinator.lastSyncDate else { return "Not synced yet" }
        if Calendar.current.isDateInToday(last) {
            return "Last full sync today, \(last.formatted(date: .omitted, time: .shortened))"
        }
        return "Last full sync \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var account: Account
    @State private var editedName = ""
    @State private var balanceText = ""
    @State private var pendingDelete = false

    private var transactions: [Transaction] {
        account.transactions.sorted { $0.posted > $1.posted }
    }

    private var monthGroups: [(month: Date, txns: [Transaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: transactions) {
            cal.dateInterval(of: .month, for: $0.posted)?.start ?? $0.posted
        }
        return grouped.map { (month: $0.key, txns: $0.value) }.sorted { $0.month > $1.month }
    }

    var body: some View {
        List {
            Section("Name") {
                TextField("Account name", text: $editedName)
                    .accessibilityIdentifier("accountNameField")
            }
            .listRowBackground(Color.surface)
            Section {
                if account.isManual {
                    // Manual accounts are user-maintained, so the balance is editable.
                    LabeledContent("Balance") {
                        TextField("0.00", text: $balanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("accountBalanceField")
                    }
                } else {
                    LabeledContent("Balance") {
                        MoneyText(value: account.balance, code: account.currency,
                                  color: balanceColor(account.balance))
                    }
                }
                if account.accountType == .cash, let avail = account.availableBalance {
                    LabeledContent("Available") {
                        MoneyText(value: avail, code: account.currency, weight: .regular, color: .textSecondary)
                    }
                }
                Picker("Type", selection: $account.accountType) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .tint(Color.textPrimary)
                if account.isManual && account.accountType.isDebt {
                    Text("Debts are stored as negative balances (e.g. -1500).")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            .listRowBackground(Color.surface)
            Section {
                Button(role: .destructive) {
                    // Pop first, then delete once the view is gone, so the
                    // detail never re-renders against a deleted model.
                    pendingDelete = true
                    dismiss()
                } label: {
                    Label("Delete Account", systemImage: "trash")
                }
                .accessibilityIdentifier("deleteAccountButton")
            } footer: {
                if !account.isManual {
                    Text("A deleted account comes back on the next sync if it's still in your SimpleFin connection.")
                }
            }
            .listRowBackground(Color.surface)
            if transactions.isEmpty {
                Section("Transactions") {
                    Text("No transactions in the synced window.").foregroundStyle(Color.textSecondary)
                }
                .listRowBackground(Color.surface)
            } else {
                ForEach(monthGroups, id: \.month) { group in
                    Section {
                        ForEach(group.txns) { txn in
                            NavigationLink(value: txn) {
                                TransactionRow(transaction: txn)
                            }
                            .accessibilityIdentifier("acctTxnRow-\(txn.id)")
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
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedName = account.displayName
            balanceText = NSDecimalNumber(decimal: account.balance).stringValue
        }
        .onChange(of: editedName) { applyRename() }
        .onChange(of: balanceText) { applyBalance() }
        .onChange(of: account.typeRaw) { try? context.save() }
        .onDisappear {
            if pendingDelete {
                context.delete(account)
                try? context.save()
            }
        }
    }

    /// Persist an edited balance for a manual account (ignores unparseable input).
    private func applyBalance() {
        guard account.isManual, let value = Decimal(string: balanceText, locale: .current) else { return }
        account.balance = value
        try? context.save()
    }

    /// Persist the edited name as a `customName` override (cleared when it's
    /// blank or matches the bank-provided name), so it survives re-syncs.
    private func applyRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        account.customName = (trimmed.isEmpty || trimmed == account.name) ? nil : trimmed
        try? context.save()
    }
}
