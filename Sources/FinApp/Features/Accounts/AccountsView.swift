import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppRouter.self) private var router
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var showingAdd = false
    @State private var path: [Account] = []

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
                }
            }
            .navigationTitle("Accounts")
            .navigationDestination(for: Account.self) { AccountDetailView(account: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
            .refreshable { await coordinator.sync() }
        }
        .onChange(of: router.selectedTab) { if router.selectedTab != 1 { path = [] } }
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
                            .font(.headline)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Chip(Money.string(groupTotal), color: groupTotal < 0 ? .negative : .textSecondary)
                    }
                    .padding(.top, 8)
                }
                HStack {
                    Text(group.type.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    MoneyText(value: group.subtotal, size: 14, weight: .semibold,
                              color: group.subtotal < 0 ? .negative : .textSecondary)
                }
            }
            .textCase(nil)
        }
    }

    private func row(_ account: Account) -> some View {
        let tint: Color = account.accountType.isDebt ? .negative : .brand
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: account.accountType.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName).foregroundStyle(Color.textPrimary)
                Chip(account.accountType.displayName, color: .textSecondary)
            }
            Spacer()
            MoneyText(value: account.balance, code: account.currency, size: 17, weight: .semibold,
                      color: account.balance < 0 ? .negative : .textPrimary)
        }
        .padding(.vertical, 4)
    }
}

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Bindable var account: Account
    @State private var editedName = ""

    private var transactions: [Transaction] {
        account.transactions.sorted { $0.posted > $1.posted }
    }

    var body: some View {
        List {
            Section("Name") {
                TextField("Account name", text: $editedName)
                    .accessibilityIdentifier("accountNameField")
            }
            .listRowBackground(Color.surface)
            Section {
                LabeledContent("Balance") {
                    MoneyText(value: account.balance, code: account.currency,
                              color: account.balance < 0 ? .negative : .textPrimary)
                }
                Picker("Type", selection: $account.accountType) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            }
            .listRowBackground(Color.surface)
            Section("Transactions") {
                if transactions.isEmpty {
                    Text("No transactions in the synced window.").foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(transactions) { txn in
                        TransactionRow(transaction: txn)
                            .contentShape(Rectangle())
                            .onTapGesture { router.openTransaction(id: txn.id) }
                            .accessibilityIdentifier("acctTxnRow-\(txn.id)")
                    }
                }
            }
            .listRowBackground(Color.surface)
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { editedName = account.displayName }
        .onChange(of: editedName) { applyRename() }
        .onChange(of: account.typeRaw) { try? context.save() }
    }

    /// Persist the edited name as a `customName` override (cleared when it's
    /// blank or matches the bank-provided name), so it survives re-syncs.
    private func applyRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        account.customName = (trimmed.isEmpty || trimmed == account.name) ? nil : trimmed
        try? context.save()
    }
}
