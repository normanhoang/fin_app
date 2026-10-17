import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(FinanceKitCoordinator.self) private var financeKit
    @Environment(AppLock.self) private var lock
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.posted, order: .reverse) private var transactions: [Transaction]
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var setupToken = ""
    @State private var showClearConfirm = false
    @State private var showDisconnectConfirm = false
    @State private var showExporter = false
    /// Bumped on tab arrival to rebuild the scroll view at the very top.
    @State private var topReset = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connectionCard
                    noticeCards
                    if financeKit.isAvailable {
                        appleWalletCard
                    }
                    SectionLabel("Appearance").padding(.horizontal, 4)
                    appearanceCard
                    SectionLabel("Security").padding(.horizontal, 4)
                    securityCard
                    SectionLabel("Data").padding(.horizontal, 4)
                    dataCard
                    Text("Your financial data is stored only on this device — there is no server we operate. Account data is fetched through SimpleFin Bridge, which connects to your banks on your behalf, so that fetch does pass through SimpleFin's service.\(financeKit.isAvailable ? " Apple Wallet accounts are read directly on this iPhone and never leave it." : "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .task { await financeKit.refreshAuthorization() }
            .screenBackground()
            .id(topReset)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .fixLargeTitleInset(trigger: topReset)
            .onChange(of: router.selectedTab) {
                // Settings has no pushable subpage, so arriving here always clears
                // subpageOpen — otherwise a stale `true` (e.g. arriving from another
                // tab's open detail) would keep paging disabled and block swiping.
                if router.selectedTab == AppTab.settings.rawValue {
                    topReset += 1
                    router.subpageOpen = false
                }
            }
            .confirmationDialog("Clear all local data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear all data", role: .destructive) { SampleData.wipeAll(in: context) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every account, transaction, budget, and history record stored on this device. This cannot be undone.")
            }
            .confirmationDialog("Disconnect from SimpleFin?", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { coordinator.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops syncing. Data already on this device is kept.")
            }
            .fileExporter(isPresented: $showExporter,
                          document: CSVDocument(text: transactionsCSV),
                          contentType: .commaSeparatedText,
                          defaultFilename: "FinApp Transactions") { _ in }
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if coordinator.isConnected {
                connectedContent
            } else {
                connectContent
            }
        }
        .modifier(ConnectionCardChrome())
    }

    /// Icon circle + title + status line shared by the SimpleFin and Apple Wallet cards.
    private func connectionHeader(icon: String, tint: Color = .brand, title: String, meta: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Full-width brand button used by the connection cards.
    private func primaryButton(_ title: String, icon: String? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small).tint(Color.appBackground)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
        }
        .font(.system(size: 13.5, weight: .semibold))
        .foregroundStyle(Color.appBackground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var connectedContent: some View {
        connectionHeader(icon: "checkmark.seal.fill", title: "Connected to SimpleFin", meta: connectionMeta)
        HStack(spacing: 10) {
            Button {
                Task {
                    await coordinator.sync()
                    await financeKit.importNow()
                }
            } label: {
                primaryButton(coordinator.isSyncing ? "Syncing…" : "Sync now",
                              icon: "arrow.triangle.2.circlepath", busy: coordinator.isSyncing)
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isSyncing)
            .accessibilityIdentifier("syncNowButton")
            Button {
                showDisconnectConfirm = true
            } label: {
                Text("Disconnect")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("disconnectButton")
        }
    }

    private var connectionMeta: String {
        var parts = ["\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")"]
        if let last = coordinator.lastSyncDate {
            if Calendar.current.isDateInToday(last) {
                parts.append("last synced today, \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append("last synced \(last.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var connectContent: some View {
        connectionHeader(icon: "link", title: "Connect to SimpleFin",
                         meta: "A setup token establishes a read-only connection.")
        TextField("", text: $setupToken,
                  prompt: Text("Paste SimpleFin setup token").foregroundStyle(Color.textTertiary),
                  axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...4)
            .foregroundStyle(Color.textPrimary)
            .padding(10)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1))
        Button {
            let token = setupToken
            setupToken = ""
            Task { await coordinator.connect(setupToken: token) }
        } label: {
            HStack(spacing: 6) {
                if coordinator.isSyncing { ProgressView().controlSize(.small).tint(Color.appBackground) }
                Text(coordinator.isSyncing ? "Connecting…" : "Connect")
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.appBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isSyncing)
        Button {
            SampleData.inject(into: context)
        } label: {
            Label("Preview with sample data", systemImage: "eye")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.brand)
        }
        .buttonStyle(.plain)
        Text("Get a setup token from your SimpleFin account. Your bank data is fetched through SimpleFin Bridge and stored only on this device.")
            .font(.system(size: 12))
            .foregroundStyle(Color.textTertiary)
        Link(destination: URL(string: "https://normanhoang.github.io/fin_app/simplefin-setup")!) {
            Text("How to set up SimpleFin →")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.brand)
        }
        .accessibilityIdentifier("simplefinSetupLink")
    }

    /// Provider notices (orange) and sync errors (negative), as tinted cards.
    @ViewBuilder
    private var noticeCards: some View {
        ForEach(coordinator.providerErrors, id: \.self) { msg in
            tintedCard(msg, icon: "exclamationmark.triangle", tint: .orange)
        }
        if let error = coordinator.errorMessage {
            tintedCard(error, icon: "xmark.octagon", tint: .negative)
        }
        if !coordinator.providerErrors.isEmpty {
            Link(destination: URL(string: "https://beta-bridge.simplefin.org/auth/login")!) {
                Text("Fix this connection at SimpleFin Bridge \u{2192}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.brand)
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("fixConnectionLink")
        }
    }

    // MARK: Apple Wallet (FinanceKit)

    @ViewBuilder
    private var appleWalletCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch financeKit.authorization {
            case .notDetermined:
                connectionHeader(icon: "wallet.pass", title: "Connect Apple Wallet",
                                 meta: "Apple Card, Cash, and Savings — read on this iPhone, no bank login.")
                Button {
                    Task { await financeKit.connect() }
                } label: {
                    primaryButton("Connect Apple Wallet")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectAppleWalletButton")
            case .authorized:
                connectionHeader(icon: "checkmark.seal.fill", title: "Connected to Apple Wallet",
                                 meta: appleWalletMeta)
                Button {
                    Task { await financeKit.importNow() }
                } label: {
                    primaryButton(financeKit.isImporting ? "Importing…" : "Import now",
                                  icon: "arrow.triangle.2.circlepath", busy: financeKit.isImporting)
                }
                .buttonStyle(.plain)
                .disabled(financeKit.isImporting)
                .accessibilityIdentifier("importAppleWalletButton")
                Text("Manage shared accounts in Settings → Privacy & Security → Wallet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            case .denied:
                connectionHeader(icon: "wallet.pass", tint: .textSecondary, title: "Apple Wallet access is off",
                                 meta: "Turn it on in Settings → Privacy & Security → Wallet. Imported accounts keep their last data.")
            }
            if let result = financeKit.lastMergeResult {
                tintedCard("Merged \(result.merged) transactions, removed \(result.removed) duplicates.",
                           icon: "checkmark.circle", tint: .brand)
            }
            if let error = financeKit.errorMessage {
                tintedCard(error, icon: "xmark.octagon", tint: .negative)
            }
        }
        .modifier(ConnectionCardChrome())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appleWalletCard")
    }

    private var appleWalletMeta: String {
        let count = accounts.filter { $0.source == .financeKit }.count
        var parts = ["\(count) \(count == 1 ? "account" : "accounts")"]
        if let last = financeKit.lastImportDate {
            if Calendar.current.isDateInToday(last) {
                parts.append("last imported today, \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append("last imported \(last.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func tintedCard(_ message: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    // MARK: Appearance / Security

    private var appearanceCard: some View {
        HStack {
            Text("Theme")
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        appearanceRaw = mode.rawValue
                    } label: {
                        Text(mode.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(appearanceRaw == mode.rawValue
                                             ? Color.appBackground : Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(appearanceRaw == mode.rawValue ? Color.brand : .clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme-\(mode.rawValue)")
                }
            }
            .padding(2)
            .background(Color.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var securityCard: some View {
        @Bindable var lock = lock
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: "#38BDF8").opacity(0.12))
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#38BDF8"))
                }
                .frame(width: 36, height: 36)
                Toggle("Require Face ID / Passcode", isOn: $lock.isEnabled)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.textPrimary)
                    .tint(Color.brand)
                    .disabled(!lock.biometryAvailable)
            }
            if !lock.biometryAvailable {
                Text("No biometrics or passcode is set up on this device.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    // MARK: Data

    private var dataCard: some View {
        VStack(spacing: 0) {
            Button {
                showExporter = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.textSecondary.opacity(0.12))
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export data")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("CSV of all transactions")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("exportDataButton")
            Divider().overlay(Color.hairline)
            Button {
                showClearConfirm = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.negative.opacity(0.10))
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.negative)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear all local data")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.negative)
                        Text("Cannot be undone")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clearDataButton")
        }
        .padding(.horizontal, 16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    /// All transactions as CSV, newest first.
    private var transactionsCSV: String {
        var lines = ["Date,Payee,Description,Category,Account,Amount,Note"]
        for txn in transactions {
            lines.append([
                txn.posted.formatted(.iso8601.year().month().day()),
                csvField(txn.payee ?? ""),
                csvField(txn.detail),
                csvField(txn.category?.name ?? ""),
                csvField(txn.account?.displayName ?? ""),
                "\(txn.amount)",
                csvField(txn.note ?? ""),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func csvField(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return raw }
        return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Minimal FileDocument wrapping the CSV text for `.fileExporter`.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Surface + brand-tinted gradient + hairline: the SimpleFin and Apple Wallet cards.
private struct ConnectionCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.surface)
                    .overlay(
                        LinearGradient(colors: [.brand.opacity(0.10), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            )
    }
}
