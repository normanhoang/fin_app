import SwiftUI

/// Asks before folding the SimpleFin copy of an Apple account into FinanceKit.
struct FinanceKitMergeSheet: View {
    @Environment(FinanceKitCoordinator.self) private var financeKit
    @Environment(SyncCoordinator.self) private var sync
    let proposal: MergeProposal
    @State private var contentHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            accountsCard
            keptList
            VStack(spacing: 6) {
                Button {
                    financeKit.confirmMerge()
                    // The unlink banner was computed by a sync that ran before this merge.
                    sync.refreshSuperseded()
                } label: {
                    Text("Merge accounts")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mergeConfirmButton")
                Button {
                    financeKit.declineMerge()
                } label: {
                    Text("Keep separate")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mergeDeclineButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 8)
        // Size the sheet to its content rather than a half-screen detent.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 44, height: 44)
                .background(Color.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Merge duplicate account?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("This account is coming in from both SimpleFin and Apple Wallet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// From (SimpleFin) → into (Apple Wallet).
    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountRow(name: proposal.simplefinName, icon: "link", source: "SimpleFin",
                       tint: .textSecondary)
            HStack(spacing: 10) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 36)
                Rectangle().fill(Color.hairline).frame(height: 1)
            }
            .padding(.vertical, 6)
            accountRow(name: proposal.financeKitName, icon: "wallet.pass", source: "Apple Wallet",
                       tint: .brand)
        }
        .cardStyle(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private func accountRow(name: String, icon: String, source: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())
            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Chip(source, color: tint)
        }
    }

    private var keptList: some View {
        VStack(alignment: .leading, spacing: 8) {
            keptRow("History, rename, categories, and notes are kept")
            keptRow("Duplicate transactions are removed")
            keptRow("Apple Wallet keeps it up to date from now on")
        }
    }

    private func keptRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.brand)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
