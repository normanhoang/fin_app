import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var showingAdd = false
    @State private var path: [Account] = []
    /// Bumped on tab arrival to rebuild the List at the very top.
    @State private var topReset = 0

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
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                })
            }
            .sorted { $0.type.sortIndex < $1.type.sortIndex }
    }

    private var assetGroups: [TypeGroup] { groups(debt: false) }
    private var debtGroups: [TypeGroup] { groups(debt: true) }
    private func total(_ groups: [TypeGroup]) -> Decimal { groups.reduce(Decimal(0)) { $0 + $1.subtotal } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "building.columns",
                        description: Text("Connect SimpleFin or add a manual account with the + button.")
                    )
                } else {
                    List {
                        // One Section per type so the inset card rounds at each type's
                        // top and bottom; an eyebrow marks the first Assets/Debts type.
                        ForEach(assetGroups) { typeSection($0, groupTitle: "Assets",
                                                            groupTotal: total(assetGroups),
                                                            showEyebrow: $0.id == assetGroups.first?.id) }
                        ForEach(debtGroups) { typeSection($0, groupTitle: "Debts",
                                                          groupTotal: total(debtGroups),
                                                          showEyebrow: $0.id == debtGroups.first?.id) }
                    }
                    .listRowSeparatorTint(Color.hairline)
                    .screenBackground()
                    .id(topReset)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Accounts")
            .fixLargeTitleInset(trigger: topReset)
            .navigationDestination(for: Account.self) { AccountDetailView(account: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("addAccountButton")
                }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
        }
        .onChange(of: router.selectedTab) {
            if router.selectedTab == AppTab.accounts.rawValue {
                router.subpageOpen = !path.isEmpty
                topReset += 1
            } else { path = [] }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.accounts.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    private func typeSection(_ group: TypeGroup, groupTitle: String, groupTotal: Decimal, showEyebrow: Bool) -> some View {
        Section {
            ForEach(group.accounts) { account in
                NavigationLink(value: account) {
                    row(account)
                }
                .listRowBackground(Color.surface)
                .accessibilityIdentifier("accountRow-\(account.id)")
            }
        } header: {
            VStack(alignment: .leading, spacing: 8) {
                if showEyebrow {
                    HStack {
                        Text(groupTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text(Money.string(groupTotal))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(balanceColor(groupTotal))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(balanceColor(groupTotal).opacity(0.14), in: Capsule())
                    }
                    .padding(.top, 8)
                }
                HStack {
                    Text(group.type.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    MoneyText(value: group.subtotal, size: 14, weight: .semibold,
                              color: balanceColor(group.subtotal))
                }
            }
            .textCase(nil)
        }
    }

    private func row(_ account: Account) -> some View {
        HStack(spacing: 12) {
            Text(account.displayName).foregroundStyle(Color.textPrimary)
            Spacer()
            MoneyText(value: account.balance, code: account.currency, size: 17, weight: .semibold,
                      color: balanceColor(account.balance))
        }
        .padding(.vertical, 4)
    }
}

/// Red for negative, green for positive, white for exactly zero.
func balanceColor(_ value: Decimal) -> Color {
    if value < 0 { return .negative }
    if value == 0 { return .textPrimary }
    return .positive
}

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
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
                            Button { router.openTransaction(id: txn.id) } label: {
                                // contentShape makes the transparent gaps (Spacer,
                                // padding) hit-testable — plain buttons only hit
                                // opaque pixels otherwise.
                                TransactionRow(transaction: txn)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
