import SwiftUI

/// Shown instead of the plain delete confirmation when the account is a likely
/// duplicate. The suggested match is preselected; picking an account merges the
/// deleted account's balance history into it (`AccountMerge`) so net worth
/// doesn't jump. `onConfirm(nil)` means delete without merging.
struct DuplicateDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: Account
    let candidates: [Account]
    let onConfirm: (Account?) -> Void
    @State private var selection: String?

    init(account: Account, candidates: [Account], suggestedID: String?,
         onConfirm: @escaping (Account?) -> Void) {
        self.account = account
        self.candidates = candidates
        self.onConfirm = onConfirm
        _selection = State(initialValue: suggestedID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Chip("Likely duplicate", color: .brand)
                        Text("\u{201C}\(account.displayName)\u{201D} looks like the same account as another one. Merge its history so net worth doesn\u{2019}t jump.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.surface)
                Section("Merge history into") {
                    ForEach(candidates) { candidate in
                        option(id: candidate.id, title: candidate.displayName) {
                            MoneyText(value: candidate.balance, code: candidate.currency,
                                      size: 14, weight: .regular, color: balanceColor(candidate.balance))
                        }
                    }
                    option(id: nil, title: "Don\u{2019}t merge") { EmptyView() }
                }
                .listRowBackground(Color.surface)
                Section {
                    Button(role: .destructive) {
                        let target = candidates.first { $0.id == selection }
                        dismiss()
                        onConfirm(target)
                    } label: {
                        Text(selection == nil ? "Delete" : "Merge & Delete")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("duplicateMergeDeleteButton")
                }
                .listRowBackground(Color.surface)
            }
            .screenBackground()
            .navigationTitle("Delete Duplicate Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func option<Trailing: View>(id: String?, title: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        let selected = selection == id
        return Button {
            selection = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.brand : Color.textSecondary)
                Text(title).foregroundStyle(Color.textPrimary)
                Spacer()
                trailing()
            }
        }
        .accessibilityIdentifier("duplicateTarget-\(id ?? "none")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
