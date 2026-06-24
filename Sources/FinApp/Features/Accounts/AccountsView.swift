import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var showingAdd = false

    /// Accounts of one type, kept together as a subsection.
    private struct TypeGroup: Identifiable {
        let type: AccountType
        let accounts: [Account]
        var id: String { type.rawValue }
        var subtotal: Decimal { accounts.reduce(Decimal(0)) { $0 + $1.balance } }
    }

    private func groups(debt: Bool) -> [TypeGroup] {
        Dictionary(grouping: accounts.filter { $0.accountType.isDebt == debt }, by: \.accountType)
            .map { TypeGroup(type: $0.key, accounts: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.type.sortIndex < $1.type.sortIndex }
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "building.columns",
                        description: Text("Connect SimpleFin or add a manual account with the + button.")
                    )
                } else {
                    List {
                        groupSection("Assets", groups(debt: false))
                        groupSection("Debts", groups(debt: true))
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
            .refreshable { await coordinator.sync() }
        }
    }

    @ViewBuilder
    private func groupSection(_ title: String, _ groups: [TypeGroup]) -> some View {
        if !groups.isEmpty {
            let total = groups.reduce(Decimal(0)) { $0 + $1.subtotal }
            Section {
                ForEach(groups) { group in
                    Text(group.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(group.accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            row(account)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Money.string(total)).foregroundStyle(.secondary)
                }
            }
            .headerProminence(.increased)
        }
    }

    private func row(_ account: Account) -> some View {
        HStack {
            Image(systemName: account.accountType.icon)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text(account.accountType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.string(account.balance, code: account.currency))
                .foregroundStyle(account.balance < 0 ? .red : .primary)
        }
    }
}

struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var account: Account

    private var transactions: [Transaction] {
        account.transactions.sorted { $0.posted > $1.posted }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Balance", value: Money.string(account.balance, code: account.currency))
                if let avail = account.availableBalance {
                    LabeledContent("Available", value: Money.string(avail, code: account.currency))
                }
                Picker("Type", selection: $account.accountType) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            }
            Section("Transactions") {
                if transactions.isEmpty {
                    Text("No transactions in the synced window.").foregroundStyle(.secondary)
                } else {
                    ForEach(transactions) { TransactionRow(transaction: $0) }
                }
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: account.typeRaw) { try? context.save() }
    }
}
