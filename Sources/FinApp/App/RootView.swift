import SwiftUI

struct RootView: View {
    @State private var router = AppRouter(selectedTab: Self.initialTab)

    private static var initialTab: Int {
        #if DEBUG
        return Int(ProcessInfo.processInfo.environment["FINAPP_TAB"] ?? "0") ?? 0
        #else
        return 0
        #endif
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            DashboardView().tag(0)
            AccountsView().tag(1)
            TransactionsView().tag(2)
            BudgetsView().tag(3)
            RecurringView().tag(4)
            SettingsView().tag(5)
        }
        // NOTE: no `.tabViewStyle(.page)` — page-swiping between tabs, each its
        // own NavigationStack, triggers a UINavigationBar layout assertion
        // (SIGABRT) mid-swipe. Tabs switch via the custom bar instead. The
        // system tab bar is hidden so only our custom bar shows.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CustomTabBar(selection: $router.selectedTab)
        }
        .environment(router)
    }
}

private struct CustomTabBar: View {
    @Binding var selection: Int
    @Environment(AppRouter.self) private var router

    private static let items: [(title: String, icon: String)] = [
        ("Dashboard", "chart.pie.fill"),
        ("Accounts", "building.columns.fill"),
        ("Transactions", "list.bullet"),
        ("Budgets", "chart.bar.fill"),
        ("Recurring", "arrow.clockwise"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                Button {
                    // Tapping the Transactions tab resets any active filter so the
                    // bar acts as a "show everything" entry point.
                    if index == 2 { router.txnFilter = .all }
                    withAnimation(.easeInOut(duration: 0.25)) { selection = index }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18))
                            .frame(height: 20)
                        Text(item.title)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(height: 12)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == index ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(item.title)")
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 2)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

#Preview {
    let container = AppSchema.makeInMemoryContainer()
    RootView()
        .modelContainer(container)
        .environment(SyncCoordinator(context: container.mainContext))
}
