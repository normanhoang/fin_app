import Foundation
import Observation

/// Bottom-bar pages in display order. Dashboard sits centre and is the default.
enum AppTab: Int, CaseIterable {
    case accounts = 0
    case transactions = 1
    case dashboard = 2
    case recurring = 3
    case settings = 4
}

/// Deep-link filter intent for the Transactions list, set when the user drills
/// in from the Dashboard.
enum TransactionFilter: Equatable {
    case all
    case income
    case spending
    case uncategorized
    case category(String)
}

/// Composable filter applied to the Transactions list. Facets AND together;
/// an empty set means "no restriction", so `TransactionFilterState()` is the
/// universal "no filter" value.
struct TransactionFilterState: Equatable {
    enum CategoryFilterItem: Hashable {
        case uncategorized
        case named(String)
    }

    enum FlowType: Equatable {
        case all
        case income
        case spending
    }

    /// Start-of-month; nil = all time.
    var month: Date?
    /// Empty = all categories.
    var categories: Set<CategoryFilterItem> = []
    var type: FlowType = .all

    var isActive: Bool { self != TransactionFilterState() }

    init() {}

    /// Map a deep-link intent onto the composable state.
    init(_ deepLink: TransactionFilter) {
        switch deepLink {
        case .all: break
        case .income: type = .income
        case .spending: type = .spending
        case .uncategorized: categories = [.uncategorized]
        case .category(let name): categories = [.named(name)]
        }
    }

    /// The caller precomputes `monthInterval` from `month` once per pass so the
    /// calendar math isn't repeated for every transaction.
    func matches(_ txn: Transaction, monthInterval: DateInterval?) -> Bool {
        // DateInterval.contains includes the end point, but calendar month
        // intervals are end-exclusive (end == next month's first instant).
        if let monthInterval,
           !(txn.posted >= monthInterval.start && txn.posted < monthInterval.end) { return false }
        if !categories.isEmpty {
            let hit = txn.category.map { categories.contains(.named($0.name)) }
                ?? categories.contains(.uncategorized)
            if !hit { return false }
        }
        switch type {
        case .all: return true
        case .income: return txn.category?.isIncome == true && txn.amount > 0
        case .spending: return txn.amount < 0 && txn.category?.isIncome != true && txn.category?.name != "Transfers"
        }
    }
}

/// App-level navigation state shared across tabs so the Dashboard and Accounts
/// can deep-link into the Transactions tab.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: Int
    var txnFilter = TransactionFilterState()
    /// Request to open a specific transaction's detail in the Transactions tab.
    var pendingTxnID: String?
    /// True when arriving at Transactions via a deep-link that should keep its
    /// filter (a Dashboard category tile or an Accounts transaction). A plain tab
    /// tap or swipe leaves this false, so Transactions resets its filter + search.
    /// Consumed by TransactionsView on arrival.
    var txnArrivalIsDeepLink = false
    /// Presents the full-screen uncategorized triage swipe flow (TriageView).
    var showTriage = false
    /// True while the active tab has a pushed subpage; pauses pager swiping so the
    /// native back-swipe pops instead of changing tabs.
    var subpageOpen = false
    /// True while a subpage is actively capturing horizontal drags (e.g. scrubbing
    /// the Net Worth chart), so the left-swipe-to-next-tab gesture stays out of the
    /// way and the scrub isn't hijacked into a tab change.
    var suppressPageSwipe = false
    /// Bumped on every "show the Transactions list" deep-link so the Transactions
    /// stack pops any pushed detail back to the (filtered) root.
    private(set) var resetToken = UUID()

    init(selectedTab: Int = AppTab.dashboard.rawValue) {
        self.selectedTab = selectedTab
    }

    /// Search text to seed the Transactions list on the next deep-link arrival
    /// (the "This merchant" card). Consumed by TransactionsView.
    var pendingSearch: String?

    /// Switch to a filtered Transactions list (root), clearing any pushed detail.
    func showTransactions(_ filter: TransactionFilter) {
        txnFilter = TransactionFilterState(filter)
        txnArrivalIsDeepLink = filter != .all
        pendingTxnID = nil
        resetToken = UUID()
        selectedTab = AppTab.transactions.rawValue
    }

    /// Switch to the Transactions list seeded with a search (merchant drill-in).
    func showTransactions(searching text: String) {
        txnFilter = TransactionFilterState()
        txnArrivalIsDeepLink = true
        pendingTxnID = nil
        pendingSearch = text
        resetToken = UUID()
        selectedTab = AppTab.transactions.rawValue
    }

    /// Switch to the Transactions tab and open one transaction's detail. Back-swiping
    /// the detail simply closes it, leaving the Transactions list showing.
    func openTransaction(id: String) {
        txnFilter = TransactionFilterState()
        txnArrivalIsDeepLink = true
        pendingTxnID = id
        selectedTab = AppTab.transactions.rawValue
    }
}
