import SwiftUI

/// Full-screen cover shown while the app is locked.
struct LockScreen: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("FinApp is Locked")
                .font(.title2.bold())
            Button {
                Task { await lock.authenticate() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            if let error = lock.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task { await lock.authenticate() }
    }
}
