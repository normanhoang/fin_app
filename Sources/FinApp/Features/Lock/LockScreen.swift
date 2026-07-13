import SwiftUI

/// Full-screen cover shown while the app is locked.
struct LockScreen: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 22) {
            BrandMark(size: 92)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            Text("FinApp is locked")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Button {
                Task { await lock.authenticate() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            if let error = lock.lastError {
                Text(error).font(.footnote).foregroundStyle(Color.negative)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        // The lock screen is inserted while the app is heading to the background
        // (lock() fires on .background), and LocalAuthentication fails with
        // biometryNotAvailable (-6) unless the app is foreground-active — so only
        // auto-prompt once the scene is actually active.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await lock.autoAuthenticate()
        }
    }
}
