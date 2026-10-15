import SwiftUI
import SwiftData

/// Account-detail section for a manual loan with a `LoanSchedule`: summary,
/// irregular extra principal, edit, and remove.
struct LoanScheduleSection: View {
    @Environment(\.modelContext) private var context
    let account: Account
    let schedule: LoanSchedule
    @State private var extraText = ""
    @State private var showExtraConfirmation = false
    @State private var editing = false

    private var extra: Decimal? {
        Decimal(string: extraText, locale: .current).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        let now = Date()
        Section("Loan schedule") {
            LabeledContent("Interest rate", value: "\(LoanDraft.text(schedule.annualRate))%")
            LabeledContent("Principal & interest", value: Money.string(schedule.pi))
            LabeledContent("Escrow", value: Money.string(schedule.escrow))
            LabeledContent("Payment day", value: "\(schedule.paymentDay)")
            if schedule.balance(asOf: now) == 0 {
                LabeledContent("Status", value: "Paid off")
            } else {
                LabeledContent("Next payment",
                               value: schedule.nextPaymentDate(asOf: now).formatted(date: .abbreviated, time: .omitted))
                if let payoff = schedule.payoffDate(asOf: now) {
                    LabeledContent("Payoff", value: payoff.formatted(.dateTime.month(.abbreviated).year()))
                }
            }
            if let principal = schedule.originalPrincipal {
                LabeledContent("Original loan", value: Money.string(principal))
            }
            if let months = schedule.termMonths {
                LabeledContent("Term", value: "\(months / 12) years")
            }
            if let start = schedule.startDate {
                LabeledContent("Start date", value: start.formatted(date: .abbreviated, time: .omitted))
            }
            HStack {
                TextField("Extra principal", text: $extraText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("loanExtraField")
                Button("Apply") { showExtraConfirmation = true }
                    .buttonStyle(.borderless)
                    .disabled(extra == nil)
                    .accessibilityIdentifier("loanApplyExtraButton")
            }
            Button("Edit schedule") { editing = true }
                .accessibilityIdentifier("loanEditButton")
            Button("Remove schedule", role: .destructive) { remove() }
                .accessibilityIdentifier("loanRemoveButton")
        }
        .listRowBackground(Color.surface)
        .confirmationDialog("Reduce balance by \(Money.string(extra ?? 0))?",
                            isPresented: $showExtraConfirmation, titleVisibility: .visible) {
            Button("Apply Extra Payment") { applyExtra() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editing) {
            EditLoanScheduleView(schedule: schedule)
        }
    }

    private func applyExtra() {
        guard let extra else { return }
        LoanUpdater.applyExtraPrincipal(extra, to: account, in: context)
        extraText = ""
    }

    /// Back to a plain manual loan; the current balance stays.
    private func remove() {
        account.loanSchedule = nil
        context.delete(schedule)
        try? context.save()
    }
}

/// Edit a schedule. Prefilled with today's computed balance; saving
/// re-anchors to the form's balance and as-of date.
struct EditLoanScheduleView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let schedule: LoanSchedule
    @State private var draft: LoanDraft

    init(schedule: LoanSchedule) {
        self.schedule = schedule
        _draft = State(initialValue: LoanDraft(schedule: schedule))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current balance") {
                    LabeledContent("Balance") {
                        TextField("0.00", text: $draft.balanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Schedule") {
                    LoanScheduleFields(draft: $draft)
                }
            }
            .navigationTitle("Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!draft.isValid)
                }
            }
        }
    }

    private func save() {
        guard case .success(let inputs) = draft.validate() else { return }
        schedule.apply(inputs)
        try? context.save()
        LoanUpdater.refresh(in: context)
        dismiss()
    }
}
