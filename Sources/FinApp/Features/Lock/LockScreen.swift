import SwiftUI

/// Full-screen cover shown while the app is locked.
struct LockScreen: View {
    @Environment(AppLock.self) private var lock

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
        .task { await lock.authenticate() }
    }
}
