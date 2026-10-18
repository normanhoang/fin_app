import SwiftUI
import SwiftData

@main
struct FinAppApp: App {
    let container: ModelContainer
    @State private var coordinator: SyncCoordinator
    @State private var financeKit: FinanceKitCoordinator
    @State private var lock: AppLock
    @State private var showSplash = true
    /// True while the scene isn't frontmost. iOS snapshots the app for the
    /// app switcher during `.inactive` — before the `.background` lock fires —
    /// so we cover the content the moment focus is lost.
    @State private var isInactive = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

    init() {
        #if DEBUG
        let isUITest = ProcessInfo.processInfo.environment["FINAPP_UITEST"] == "1"
        if isUITest {
            UserDefaults.standard.removeObject(forKey: "appLockEnabled")
        }
        let appLock = AppLock()
        if isUITest && ProcessInfo.processInfo.environment["FINAPP_UI_LOCK_ON_BACKGROUND"] == "1" {
            appLock.isEnabled = true
            appLock.evaluator = { _ in false }
            // isEnabled's didSet persisted the flag; scrub it so it can't leak
            // into a later non-UI-test launch on the same simulator/device.
            UserDefaults.standard.removeObject(forKey: "appLockEnabled")
        }
        _lock = State(initialValue: appLock)
        let container = isUITest ? AppSchema.makeInMemoryContainer() : AppSchema.makeContainer()
        self.container = container
        _coordinator = State(initialValue: SyncCoordinator(context: container.mainContext))
        let financeKit = FinanceKitCoordinator(
            source: ProcessInfo.processInfo.environment["FINAPP_FK_DEMO"] == "1" ? DemoFinanceKitSource()
                : isUITest ? UnavailableFinanceKitSource() : FinanceKitSources.make(),
            context: container.mainContext)
        if ProcessInfo.processInfo.environment["FINAPP_MERGE_DEMO"] == "1" {
            // Show the merge sheet with stand-in accounts (design review / UI test).
            financeKit.pendingMerge = MergeProposal(
                financeKitAccountID: "financekit-demo", simplefinAccountID: "simplefin-demo",
                financeKitName: "Apple Card", simplefinName: "Apple Card")
        }
        _financeKit = State(initialValue: financeKit)

        if isUITest || ProcessInfo.processInfo.environment["FINAPP_SAMPLE"] == "1" {
            SampleData.inject(into: container.mainContext)
        }
        if isUITest && ProcessInfo.processInfo.environment["FINAPP_DUP_DEMO"] == "1" {
            SampleData.injectDuplicateDemo(into: container.mainContext)
        }
        if let repair = ProcessInfo.processInfo.environment["FINAPP_REPAIR_ORPHAN"] {
            print("[OrphanRepair] \(OrphanRepair.run(repair, in: container.mainContext))")
        }
        if isUITest {
            // The store is in-memory per launch, but UserDefaults persist across
            // UI-test launches — reset the dashboard filter flags so tests can't
            // leak state into each other and become order-dependent.
            UserDefaults.standard.removeObject(forKey: "dashCategoryAuto")
            UserDefaults.standard.removeObject(forKey: "dashHideUncategorized")
        }
        #else
        _lock = State(initialValue: AppLock())
        let container = AppSchema.makeContainer()
        self.container = container
        _coordinator = State(initialValue: SyncCoordinator(context: container.mainContext))
        _financeKit = State(initialValue: FinanceKitCoordinator(
            source: FinanceKitSources.make(),
            context: container.mainContext))
        #endif

        // Seed default categories at launch so newly-shipped defaults reach
        // existing installs without waiting for a network sync.
        CategorySeed.seedIfNeeded(in: self.container.mainContext)
        CategorySeed.ensureMissing(in: self.container.mainContext)
        CategorySeed.ensureExclusions(in: self.container.mainContext)
        AccountType.migrateOther(in: self.container.mainContext)
        AccountSource.migrateManual(in: self.container.mainContext)
        LoanUpdater.refresh(in: self.container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(coordinator)
                    .environment(financeKit)
                    .environment(lock)
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(0.7))
                            withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                        }
                }
                PrivacyShieldHost(
                    lock: lock,
                    state: .resolve(
                        isInactive: isInactive,
                        lockEnabled: lock.isEnabled,
                        unlocked: lock.isUnlocked
                    )
                )
                .frame(width: 0, height: 0)
            }
            .tint(.brand)
            .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            isInactive = phase != .active
            if phase == .background {
                lock.lock()
            } else if phase == .active {
                // Only resync on foreground if it's been over an hour since the last
                // successful sync, instead of hitting SimpleFin on every open.
                if coordinator.isConnected { Task { await coordinator.syncIfStale() } }
                Task { await financeKit.importIfStale() }
                LoanUpdater.refresh(in: container.mainContext)
            }
        }
    }
}
