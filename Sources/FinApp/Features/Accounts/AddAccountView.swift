import SwiftUI
import SwiftData

/// Create a manual account (property, loan, etc.) that lives alongside synced
/// SimpleFin accounts. Its `manual-` id never collides with SimpleFin ids, so
/// sync leaves it untouched.
struct AddAccountView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .cash
    @State private var balanceText = ""

    private var balance: Decimal? { Decimal(string: balanceText, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases) { type in
                            Label(type.displayName, systemImage: type.icon).tag(type)
                        }
                    }
                    .tint(Color.textPrimary)
                }
                .listRowBackground(Color.surface)
                Section("Balance") {
                    TextField("0.00", text: $balanceText)
                        .keyboardType(.numbersAndPunctuation)
                }
                .listRowBackground(Color.surface)
                if type.isDebt {
                    Text("Debts are stored as negative balances. Enter the amount owed as a negative number (e.g. -1500).")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .listRowBackground(Color.surface)
                }
            }
            .screenBackground()
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || balance == nil)
                }
            }
        }
    }

    private func save() {
        guard let balance else { return }
        let account = Account(
            id: "manual-\(UUID().uuidString)",
            org: "Manual",
            name: name.trimmingCharacters(in: .whitespaces),
            currency: "USD",
            balance: balance,
            balanceDate: Date(),
            typeRaw: type.rawValue,
            isManual: true
        )
        context.insert(account)
        try? context.save()
        dismiss()
    }
}
