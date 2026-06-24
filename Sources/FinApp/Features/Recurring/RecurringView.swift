import SwiftUI
import SwiftData

struct RecurringView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringBill.nextDue) private var bills: [RecurringBill]

    private var confirmed: [RecurringBill] { bills.filter { $0.confirmed && !$0.dismissed } }
    private var candidates: [RecurringBill] { bills.filter { !$0.confirmed && !$0.dismissed } }

    var body: some View {
        NavigationStack {
            if confirmed.isEmpty && candidates.isEmpty {
                ContentUnavailableView(
                    "No Recurring Bills",
                    systemImage: "arrow.clockwise",
                    description: Text("Subscriptions and bills are detected automatically as you sync.")
                )
                .navigationTitle("Recurring")
            } else {
                List {
                    if !confirmed.isEmpty {
                        Section("Upcoming") {
                            ForEach(confirmed) { RecurringRow(bill: $0) }
                        }
                    }
                    if !candidates.isEmpty {
                        Section {
                            ForEach(candidates) { bill in
                                RecurringRow(bill: bill)
                                    .contextMenu {
                                        Button { confirm(bill) } label: {
                                            Label("Confirm", systemImage: "checkmark")
                                        }
                                        Button(role: .destructive) { dismiss(bill) } label: {
                                            Label("Dismiss", systemImage: "xmark")
                                        }
                                    }
                            }
                        } header: {
                            Text("Detected")
                        } footer: {
                            Text("Press and hold a detected bill to confirm it or dismiss a false match.")
                        }
                    }
                }
                .navigationTitle("Recurring")
            }
        }
    }

    private func confirm(_ bill: RecurringBill) {
        bill.confirmed = true
        try? context.save()
    }

    private func dismiss(_ bill: RecurringBill) {
        bill.dismissed = true
        try? context.save()
    }
}

struct RecurringRow: View {
    let bill: RecurringBill

    private var subtitle: String {
        var text = bill.cadence.rawValue.capitalized
        if let due = bill.nextDue {
            text += " · next \(due.formatted(.dateTime.month().day()))"
        }
        return text
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.merchantName.capitalized)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.string(bill.expectedAmount))
                .foregroundStyle(.secondary)
        }
    }
}
