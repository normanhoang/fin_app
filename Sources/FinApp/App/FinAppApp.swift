import SwiftUI
import SwiftData

@main
struct FinAppApp: App {
    let container: ModelContainer
    @State private var coordinator: SyncCoordinator
    @State private var lock = AppLock()
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

    init() {
        #if DEBUG
        let isUITest = ProcessInfo.processInfo.environment["FINAPP_UITEST"] == "1"
        let container = isUITest ? AppSchema.makeInMemoryContainer() : AppSchema.makeContainer()
        self.container = container
        _coordinator = State(initialValue: SyncCoordinator(context: container.mainContext))

        if isUITest || ProcessInfo.processInfo.environment["FINAPP_SAMPLE"] == "1" {
            SampleData.inject(into: container.mainContext)
        }
        #else
        let container = AppSchema.makeContainer()
        self.container = container
        _coordinator = State(initialValue: SyncCoordinator(context: container.mainContext))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(coordinator)
                    .environment(lock)
                if lock.isEnabled && !lock.isUnlocked {
                    LockScreen()
                        .environment(lock)
                }
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(0.9))
                            withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                        }
                }
            }
            .tint(.brand)
            .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                lock.lock()
            } else if phase == .active, coordinator.isConnected {
                // Only resync on foreground if it's been over an hour since the last
                // successful sync, instead of hitting SimpleFin on every open.
                Task { await coordinator.syncIfStale() }
            }
        }
    }
}
