import SwiftUI

/// Asks before folding the SimpleFin copy of an Apple account into FinanceKit.
struct FinanceKitMergeSheet: View {
    @Environment(FinanceKitCoordinator.self) private var financeKit
    let proposal: MergeProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge accounts?")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("**\(proposal.simplefinName)** (SimpleFin) looks like the same account as **\(proposal.financeKitName)** (Apple Wallet). Merging keeps your history, rename, categories, and notes, and removes duplicate transactions.")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Button {
                financeKit.confirmMerge()
            } label: {
                Text("Merge")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mergeConfirmButton")
            Button("Keep separate") { financeKit.declineMerge() }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("mergeDeclineButton")
        }
        .padding(24)
        .presentationDetents([.medium])
        .background(Color.appBackground)
    }
}
