import SwiftUI

/// Brief launch splash: the app icon, enlarged, over its own navy gradient.
struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 14/255, green: 23/255, blue: 38/255),
                         Color(red: 19/255, green: 36/255, blue: 59/255)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Image("SplashIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
    }
}

#Preview {
    SplashView()
}
