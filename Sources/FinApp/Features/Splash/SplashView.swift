import SwiftUI

/// Brief launch splash: the brand mark over the app's charcoal background.
struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.surfaceElevated, Color.appBackground],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                BrandMark(size: 132)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                Text("FinApp")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
            }
        }
    }
}

#Preview {
    SplashView()
}
