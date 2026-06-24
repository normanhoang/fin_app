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

    var body: some View {
        // A horizontal paging ScrollView restores swipe-between-tabs WITHOUT the
        // UIPageViewController that made `TabView(.page)` crash on swipe, and with
        // no system tab bar to peek out from under the custom bar.
        // Pager and bar are stacked (not overlaid) so each page's List ends above
        // the bar instead of being clipped by it — safeAreaInset doesn't propagate
        // through the horizontal pager to the nested Lists.
        VStack(spacing: 0) {
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
            .id(tag)
    }
}

private struct CustomTabBar: View {
    @Binding var selection: Int
    @Environment(AppRouter.self) private var router

    // Budgets is hidden for now (page omitted above too).
    private static let items: [(title: String, icon: String)] = [
        ("Dashboard", "chart.pie.fill"),
        ("Accounts", "building.columns.fill"),
        ("Transactions", "list.bullet"),
        ("Recurring", "arrow.clockwise"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                Button {
                    // Tapping the Transactions tab resets any active filter and pops
                    // to the list root, so the bar is a "show everything" entry point.
                    // No animation: switch straight to the page rather than sliding it in.
                    if index == 2 {
                        router.showTransactions(.all)
                    } else {
                        selection = index
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17))
                            .frame(height: 20)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background {
                                if selection == index {
                                    Capsule().fill(Color.brand.opacity(0.18))
                                }
                            }
                        Text(item.title)
                            .font(.system(size: 9, weight: selection == index ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // A floating Liquid Glass pill (iOS 26), with a translucent-material fallback.
        .glassTabBar()
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
    }
}

private extension View {
    /// Liquid Glass capsule on iOS 26+, falling back to an ultra-thin material.
    @ViewBuilder
    func glassTabBar() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

#Preview {
    let container = AppSchema.makeInMemoryContainer()
    RootView()
        .modelContainer(container)
        .environment(SyncCoordinator(context: container.mainContext))
}
