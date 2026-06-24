import SwiftUI

struct SettingsView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppLock.self) private var lock
    @Environment(\.modelContext) private var context
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var setupToken = ""

    var body: some View {
        NavigationStack {
            List {
                if coordinator.isConnected {
                    connectedSection
                } else {
                    connectSection
                }

                if !coordinator.providerErrors.isEmpty {
                    Section("SimpleFin Notices") {
                        ForEach(coordinator.providerErrors, id: \.self) { msg in
                            Label(msg, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .listRowBackground(Color.surface)
                }

                if let error = coordinator.errorMessage {
                    Section {
                        Label(error, systemImage: "xmark.octagon")
                            .foregroundStyle(Color.negative)
                    }
                    .listRowBackground(Color.surface)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.surface)

                Section("Security") {
                    @Bindable var lock = lock
                    Toggle("Require Face ID / Passcode", isOn: $lock.isEnabled)
                        .disabled(!lock.biometryAvailable)
                    if !lock.biometryAvailable {
                        Text("No biometrics or passcode is set up on this device.")
                            .font(.footnote).foregroundStyle(Color.textSecondary)
                    }
                }
                .listRowBackground(Color.surface)

                Section {
                    Text("Your financial data is stored only on this device — there is no server we operate. Account data is fetched through SimpleFin Bridge, which connects to your banks on your behalf, so that fetch does pass through SimpleFin's service.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                } header: {
                    Text("Privacy")
                }
                .listRowBackground(Color.surface)

                #if DEBUG
                Section("Developer") {
                    Button("Load Sample Data") { SampleData.inject(into: context) }
                }
                .listRowBackground(Color.surface)
                #endif
            }
            .listRowSeparatorTint(Color.hairline)
            .screenBackground()
            .navigationTitle("Settings")
        }
    }

    private var connectSection: some View {
        Section {
            TextField("Paste SimpleFin setup token", text: $setupToken, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
            Button {
                let token = setupToken
                setupToken = ""
                Task { await coordinator.connect(setupToken: token) }
            } label: {
                if coordinator.isSyncing {
                    HStack { ProgressView(); Text("Connecting…") }
                } else {
                    Text("Connect")
                }
            }
            .disabled(setupToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isSyncing)
        } header: {
            Text("Connect")
        } footer: {
            Text("Get a setup token from your SimpleFin account. It is used once to establish a read-only connection. Your bank data is fetched through SimpleFin Bridge and stored only on this device.")
        }
        .listRowBackground(Color.surface)
    }

    private var connectedSection: some View {
        Section("Connection") {
            Label("Connected to SimpleFin", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.positive)
            if let last = coordinator.lastSyncDate {
                LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                Task { await coordinator.sync() }
            } label: {
                if coordinator.isSyncing {
                    HStack { ProgressView(); Text("Syncing…") }
                } else {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(coordinator.isSyncing)
            Button(role: .destructive) {
                coordinator.disconnect()
            } label: {
                Label("Disconnect", systemImage: "minus.circle")
            }
        }
        .listRowBackground(Color.surface)
    }
}
