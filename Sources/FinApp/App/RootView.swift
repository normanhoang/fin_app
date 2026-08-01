import SwiftUI

struct RootView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @State private var router = AppRouter(selectedTab: Self.initialTab)

    static let tabCount = 5

    private static var initialTab: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["FINAPP_TAB"], let i = Int(raw) { return i }
        #endif
        return AppTab.dashboard.rawValue
    }

    /// Drives the paging ScrollView and the custom bar from the same source.
    /// Reading it updates the bar as the user swipes; writing it (tab tap or a
    /// Dashboard deep-link) scrolls to that page.
    private var page: Binding<Int?> {
        Binding(get: { router.selectedTab }, set: { if let new = $0 { router.selectedTab = new } })
    }

    @State private var barHeight: CGFloat = 0
    // Live offset for the interactive left-swipe slide on a subpage (<= 0), and
    // the page width it animates across.
    @State private var dragX: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    // Set at swipe-commit so the tab bar highlights the destination immediately;
    // router.selectedTab only changes when the slide animation completes.
    @State private var pendingTab: Int?

    var body: some View {
        // A horizontal paging ScrollView restores swipe-between-tabs WITHOUT the
        // UIPageViewController that made `TabView(.page)` crash on swipe. The glass
        // bar floats over the pages; each page reserves a bottom safe-area inset
        // equal to the bar height, so content scrolls UNDER the translucent bar
        // while the last row still clears it.
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        // Order: Accounts · Transactions · Dashboard · Recurring · Settings.
                        // (Budgets hidden for now, kept in the codebase.)
                        pageView(AccountsView(), AppTab.accounts.rawValue)
                        pageView(TransactionsView(), AppTab.transactions.rawValue)
                        pageView(DashboardView(), AppTab.dashboard.rawValue)
                        pageView(RecurringView(), AppTab.recurring.rawValue)
                        pageView(SettingsView(), AppTab.settings.rawValue)
                    }
                    .scrollTargetLayout()
                    // Transient shift for the subpage left-swipe slide: moves the
                    // current page left so the already-laid-out next page peeks in.
                    .offset(x: dragX)
                }
                .scrollTargetBehavior(.paging)
                // Pause tab paging while a detail is open so the native back-swipe pops.
                .scrollDisabled(router.subpageOpen)
                // Capture the page width so the slide can animate across exactly one page.
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { pageWidth = geo.size.width }
                        .onChange(of: geo.size.width) { pageWidth = geo.size.width }
                })
                // With paging paused on a subpage, a LEFT-only interactive slide
                // pages to the next tab (which clears the tab's path, closing the
                // detail). simultaneousGesture keeps the native right back-swipe and
                // the detail List's vertical scroll working; it never consumes the touch.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard router.subpageOpen, !router.suppressPageSwipe,
                                  router.selectedTab < Self.tabCount - 1 else { return }
                            let dx = value.translation.width, dy = value.translation.height
                            guard dx < 0 else { dragX = 0; return }
                            // Horizontal-dominance gate only until the slide engages;
                            // dropping it mid-slide would snap the page back on any
                            // momentarily-vertical wobble.
                            guard dragX < 0 || abs(dx) > abs(dy) else { return }
                            // +10 offsets the gesture's activation distance so the
                            // slide starts from 0 instead of jumping to -10pt.
                            dragX = min(max(dx + 10, -pageWidth), 0)
                        }
                        .onEnded { value in
                            guard router.subpageOpen, !router.suppressPageSwipe,
                                  router.selectedTab < Self.tabCount - 1 else { dragX = 0; return }
                            // Commit on either a past-30% drag or a fast leftward flick,
                            // so a quick flick doesn't stall. Require the slide to have
                            // engaged (dragX < 0) first, so a vertical swipe that drifts
                            // slightly left — which never passes onChanged's dominance gate —
                            // can't page via the velocity path alone.
                            let commit = dragX < 0 && (-value.translation.width > pageWidth * 0.3 || value.velocity.width < -350)
                            // Seed the spring with the finger's release velocity
                            // (normalized to the remaining travel, per interpolatingSpring's
                            // contract) so finger-up hands off without a hitch.
                            let target: CGFloat = commit ? -pageWidth : 0
                            let remaining = target - dragX
                            let v = remaining != 0 ? value.velocity.width / remaining : 0
                            let spring = Animation.interpolatingSpring(stiffness: 180, damping: 22,
                                                                       initialVelocity: v)
                            if commit {
                                // Highlight the destination tab in the bar right away;
                                // the real tab change waits for the slide to finish.
                                pendingTab = router.selectedTab + 1
                                withAnimation(spring) {
                                    dragX = -pageWidth
                                } completion: {
                                    // scrollPosition jumps the viewport to the next page
                                    // and we drop the manual shift in the same (non-animated)
                                    // step, so there's no flash. The tab change also pops
                                    // the open detail via each tab's onChange(of: selectedTab).
                                    router.selectedTab += 1
                                    pendingTab = nil
                                    dragX = 0
                                }
                            } else {
                                withAnimation(spring) { dragX = 0 }
                            }
                        }
                )
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

            // The bar shows pendingTab during a subpage swipe-commit so the
            // highlight moves with the gesture, not after the slide animation.
            CustomTabBar(selection: Binding(
                get: { pendingTab ?? router.selectedTab },
                set: { router.selectedTab = $0 }
            ))
                .background(GeometryReader { geo in
                    Color.clear.preference(key: BarHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        }
        // Keep the keyboard from resizing the pager (it would shift paging offsets
        // and make a swipe jump two pages).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .fullScreenCover(isPresented: Binding(
            get: { router.showTriage },
            set: { router.showTriage = $0 }
        )) {
            TriageView()
        }
        .environment(router)
        .background(KeyboardDismisser())
        // Dismiss the keyboard when changing pages (tab tap or swipe).
        .onChange(of: router.selectedTab) { Keyboard.dismiss() }
        .task {
            // Auto-sync on open (throttled; skipped if not connected). Recurring
            // dedupe runs after every sync inside RecurringDetector.refresh.
            if coordinator.isConnected { await coordinator.syncIfStale() }
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

    // Order matches the pager: Accounts · Transactions · Dashboard · Recurring · Settings.
    private static let items: [(title: String, icon: String)] = [
        ("Accounts", "building.columns.fill"),
        ("Transactions", "list.bullet"),
        ("Dashboard", "chart.line.uptrend.xyaxis"),
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
        let isActive = selection == index
        return Button {
            // Tapping the Transactions tab resets any active filter and pops to the
            // list root, so the bar is a "show everything" entry point.
            if index == AppTab.transactions.rawValue {
                router.showTransactions(.all)
            } else {
                selection = index
            }
        } label: {
            VStack(spacing: 4) {
                // Fixed-size box so the active pill never shifts layout — keeps every
                // icon and label on the same baseline.
                ZStack {
                    if isActive {
                        Capsule().fill(Color.brand.opacity(0.18))
                            .matchedGeometryEffect(id: "activePill", in: pill)
                    }
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 52, height: 30)
                Text(item.title)
                    .font(.system(size: 9, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(height: 13)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? Color.brand : Color.textSecondary)
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
            // Plain (non-interactive) glass: no scale/enlarge response on touch.
            glassEffect(.regular, in: Capsule())
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
