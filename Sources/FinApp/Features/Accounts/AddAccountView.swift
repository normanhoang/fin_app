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

    /// Grid order + short labels: Cash · Property · Investment / Credit · Loan.
    private static let typeTiles: [(type: AccountType, label: String, icon: String)] = [
        (.cash, "Cash", "banknote"),
        (.property, "Property", "house"),
        (.investment, "Investment", "chart.line.uptrend.xyaxis"),
        (.creditCard, "Credit", "creditcard"),
        (.loan, "Loan", "mappin.and.ellipse"),
    ]

    private var magnitude: Decimal? { Decimal(string: balanceText, locale: .current) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameCard
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Type")
                        typeGrid
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Balance")
                        balanceCard
                    }
                    infoCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || magnitude == nil)
                }
            }
        }
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
            TextField("Family home", text: $name)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("accountNameField")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var typeGrid: some View {
        let rows = [Array(Self.typeTiles.prefix(3)), Array(Self.typeTiles.dropFirst(3))]
        return GeometryReader { geo in
            let spacing: CGFloat = 12
            let tileWidth = (geo.size.width - spacing * 2) / 3
            VStack(spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row, id: \.type) { tile in
                            typeTile(tile)
                                .frame(width: tileWidth, height: 80)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 172)
    }

    private func typeTile(_ tile: (type: AccountType, label: String, icon: String)) -> some View {
        let selected = type == tile.type
        return Button {
            type = tile.type
        } label: {
            VStack(spacing: 8) {
                Image(systemName: tile.icon)
                    .font(.system(size: 20, weight: .regular))
                Text(tile.label)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.brand : Color.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.brand.opacity(0.10) : Color.surface,
                       in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.brand.opacity(0.6) : Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("accountType-\(tile.label)")
    }

    private var balanceCard: some View {
        HStack(spacing: 6) {
            Text("$")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.textSecondary)
            TextField("0.00", text: $balanceText)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.textPrimary)
                .keyboardType(.decimalPad)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Text("Manual accounts aren't synced — update the balance yourself. Credit cards and loans are stored as debts; enter the amount you owe.")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private func save() {
        guard let magnitude else { return }
        let account = Account(
            id: "manual-\(UUID().uuidString)",
            org: "Manual",
            name: name.trimmingCharacters(in: .whitespaces),
            currency: "USD",
            balance: type.signedBalance(from: magnitude),
            balanceDate: Date(),
            typeRaw: type.rawValue,
            isManual: true
        )
        context.insert(account)
        try? context.save()
        dismiss()
    }
}
