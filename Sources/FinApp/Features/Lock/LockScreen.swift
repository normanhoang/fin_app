import SwiftUI

/// Full-screen cover shown while the app is locked.
struct LockScreen: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            // Faint brand radial glow behind the mark.
            RadialGradient(colors: [Color.brand.opacity(0.10), .clear],
                           center: .center, startRadius: 0, endRadius: 260)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                BrandMark(size: 88)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                VStack(spacing: 8) {
                    Text("FinApp is locked")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Your balances stay hidden until you unlock.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)
                Button {
                    Task { await lock.authenticate() }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(width: 220)
                        .frame(height: 52)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .brand.opacity(0.4), radius: 16, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                if let error = lock.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.negative)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
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
