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

/// Active filter applied to the Transactions list, set when the user drills in
/// from the Dashboard.
enum TransactionFilter: Equatable {
    case all
    case income
    case spending
    case uncategorized
    case category(String)
}

/// App-level navigation state shared across tabs so the Dashboard and Accounts
/// can deep-link into the Transactions tab.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: Int
    var txnFilter: TransactionFilter = .all
    /// Request to open a specific transaction's detail in the Transactions tab.
    var pendingTxnID: String?
    /// True when arriving at Transactions via a deep-link that should keep its
    /// filter (a Dashboard category tile or an Accounts transaction). A plain tab
    /// tap or swipe leaves this false, so Transactions resets its filter + search.
    /// Consumed by TransactionsView on arrival.
    var txnArrivalIsDeepLink = false
    /// True while the active tab has a pushed subpage; pauses pager swiping so the
    /// native back-swipe pops instead of changing tabs.
    var subpageOpen = false
    /// Bumped on every "show the Transactions list" deep-link so the Transactions
    /// stack pops any pushed detail back to the (filtered) root.
    private(set) var resetToken = UUID()

    init(selectedTab: Int = AppTab.dashboard.rawValue) {
        self.selectedTab = selectedTab
    }

    /// Switch to a filtered Transactions list (root), clearing any pushed detail.
    func showTransactions(_ filter: TransactionFilter) {
        txnFilter = filter
        txnArrivalIsDeepLink = filter != .all
        pendingTxnID = nil
        resetToken = UUID()
        selectedTab = AppTab.transactions.rawValue
    }

    /// Switch to the Transactions tab and open one transaction's detail. Back-swiping
    /// the detail simply closes it, leaving the Transactions list showing.
    func openTransaction(id: String) {
        txnFilter = .all
        txnArrivalIsDeepLink = true
        pendingTxnID = id
        selectedTab = AppTab.transactions.rawValue
    }
}
