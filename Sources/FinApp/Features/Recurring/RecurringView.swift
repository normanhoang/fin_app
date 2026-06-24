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
                        Section {
                            ForEach(confirmed) { bill in
                                RecurringRow(bill: bill)
                                    .contextMenu {
                                        Button(role: .destructive) { dismiss(bill) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Text("Upcoming")
                        } footer: {
                            Text("Press and hold a bill to remove it.")
                        }
                        .listRowBackground(Color.surface)
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
                        .listRowBackground(Color.surface)
                    }
                }
                .listRowSeparatorTint(Color.hairline)
                .screenBackground()
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

    private var dueText: String? {
        bill.nextDue.map { "next \($0.formatted(.dateTime.month().day()))" }
    }

    var body: some View {
        let color = Color(hex: bill.category?.colorHex ?? "#8E8E93")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(bill.merchantName.capitalized).foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Chip(bill.cadence.rawValue.capitalized, color: .brand)
                    if let dueText {
                        Text(dueText).font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
            }
            Spacer()
            MoneyText(value: bill.expectedAmount, size: 16, weight: .semibold, color: .textSecondary)
        }
        .padding(.vertical, 2)
    }
}
