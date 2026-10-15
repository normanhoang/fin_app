import SwiftUI

/// Loan schedule inputs, as bare rows so they work inside a `Form` section
/// (Edit Schedule) and inside a card `VStack` (Add Account). The balance
/// field itself is owned by the caller.
struct LoanScheduleFields: View {
    @Binding var draft: LoanDraft

    var body: some View {
        DatePicker("As of", selection: $draft.asOf, in: ...Date(), displayedComponents: .date)
            .accessibilityIdentifier("loanAsOfPicker")
        field("Interest rate %", text: $draft.rateText, prompt: "6.25", id: "loanRateField")
        field("Monthly payment (total)", text: $draft.totalText, prompt: "0.00", id: "loanPaymentField")
        field("Escrow (taxes & insurance)", text: $draft.escrowText, prompt: "0.00", id: "loanEscrowField")
        Stepper("Payment day: \(draft.paymentDay)", value: $draft.paymentDay, in: 1...28)
            .accessibilityIdentifier("loanPaymentDayStepper")
        Text("Optional")
            .font(.caption).foregroundStyle(Color.textSecondary)
        field("Original principal", text: $draft.principalText, prompt: "0.00", id: "loanPrincipalField")
        field("Term (years)", text: $draft.termYearsText, prompt: "30", id: "loanTermField", decimal: false)
        Toggle("Start date", isOn: $draft.hasStartDate)
        if draft.hasStartDate {
            DatePicker("Started", selection: $draft.startDate, displayedComponents: .date)
        }
        switch draft.validate() {
        case .success(let inputs):
            Text(inputs.preview())
                .font(.caption).foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("loanPreview")
        case .failure(let problem):
            if let message = problem.message {
                Text(message)
                    .font(.caption).foregroundStyle(Color.negative)
                    .accessibilityIdentifier("loanError")
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String,
                       id: String, decimal: Bool = true) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
