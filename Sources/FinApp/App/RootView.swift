import SwiftUI

struct RootView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context
    @State private var router = AppRouter(selectedTab: Self.initialTab)

    static let tabCount = 5

    private static var initialTab: Int {
        #if DEBUG
        return Int(ProcessInfo.processInfo.environment["FINAPP_TAB"] ?? "0") ?? 0
        #else
        return 0
        #endif
    }

    /// Drives the paging ScrollView and the custom bar from the same source.
    /// Reading it updates the bar as the user swipes; writing it (tab tap or a
    /// Dashboard deep-link) scrolls to that page.
    private var page: Binding<Int?> {
        Binding(get: { router.selectedTab }, set: { if let new = $0 { router.selectedTab = new } })
    }

    @State private var barHeight: CGFloat = 0

    var body: some View {
        // A horizontal paging ScrollView restores swipe-between-tabs WITHOUT the
        // UIPageViewController that made `TabView(.page)` crash on swipe. The glass
        // bar floats over the pages; each page reserves a bottom safe-area inset
        // equal to the bar height, so content scrolls UNDER the translucent bar
        // while the last row still clears it.
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        // Budgets is intentionally hidden for now (kept in the codebase
                        // for later). Indices stay 0-based with Budgets removed.
                        pageView(DashboardView(), 0)
                        pageView(AccountsView(), 1)
                        pageView(TransactionsView(), 2)
                        pageView(RecurringView(), 3)
                        pageView(SettingsView(), 4)
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                // scrollPosition is the single source of truth: it scrolls on
                // programmatic tab changes (tab bar, Dashboard/Accounts deep-links)
                // and updates the tab on swipe.
                .scrollPosition(id: page)
                .scrollIndicators(.hidden)
                // Dismiss the keyboard the moment a swipe begins, on a stable
                // layout, so paging stays smooth and doesn't skip a page.
                .scrollDismissesKeyboard(.immediately)
                // scrollPosition's initial value isn't honored on first render, so
                // jump to the launch tab once.
                .onAppear { proxy.scrollTo(router.selectedTab) }
            }

            CustomTabBar(selection: $router.selectedTab)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: BarHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        }
        // Keep the keyboard from resizing the pager (it would shift paging offsets
        // and make a swipe jump two pages).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .ignoresSafeArea(.container, edges: .horizontal)
        .environment(router)
        .background(KeyboardDismisser())
        // Dismiss the keyboard when changing pages (tab tap or swipe).
        .onChange(of: router.selectedTab) { Keyboard.dismiss() }
        .task {
            // Collapse any pre-existing duplicate recurring bills, then auto-sync
            // on open (throttled; skipped if not connected).
            RecurringStore.dedupe(in: context)
            if coordinator.isConnected { await coordinator.sync() }
        }
    }

    private func pageView(_ view: some View, _ tag: Int) -> some View {
        view
            .containerRelativeFrame(.horizontal)
            // Scroll views inside each page add this much bottom content margin so
            // their last row clears the floating bar (see `screenBackground`).
            .environment(\.bottomBarInset, max(barHeight, 72) + 24)
            .id(tag)
    }
}

private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CustomTabBar: View {
    @Binding var selection: Int
    @Environment(AppRouter.self) private var router
    @Namespace private var pill

    // Budgets is hidden for now (page omitted above too).
    private static let items: [(title: String, icon: String)] = [
        ("Dashboard", "chart.pie.fill"),
        ("Accounts", "building.columns.fill"),
        ("Transactions", "list.bullet"),
        ("Recurring", "arrow.clockwise"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                tab(index, item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        // A floating Liquid Glass pill (iOS 26 interactive glass), with a
        // translucent-material fallback. No opaque background, so page content
        // shows through underneath.
        .glassTabBar()
        .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: selection)
    }

    private func tab(_ index: Int, _ item: (title: String, icon: String)) -> some View {
        Button {
            // Tapping the Transactions tab resets any active filter and pops to the
            // list root, so the bar is a "show everything" entry point.
            if index == 2 {
                router.showTransactions(.all)
            } else {
                selection = index
            }
        } label: {
            VStack(spacing: 4) {
                // Fixed-size box so the active pill never shifts layout — keeps every
                // icon and label on the same baseline.
                ZStack {
                    if selection == index {
                        Capsule().fill(Color.brand.opacity(0.18))
                            .matchedGeometryEffect(id: "activePill", in: pill)
                    }
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 52, height: 30)
                Text(item.title)
                    .font(.system(size: 9, weight: selection == index ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selection == index ? Color.brand : Color.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(item.title)")
    }
}

private extension View {
    /// Liquid Glass capsule on iOS 26+, falling back to an ultra-thin material.
    @ViewBuilder
    func glassTabBar() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        .linearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                        startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
        }
    }
}

#Preview {
    let container = AppSchema.makeInMemoryContainer()
    RootView()
        .modelContainer(container)
        .environment(SyncCoordinator(context: container.mainContext))
}
