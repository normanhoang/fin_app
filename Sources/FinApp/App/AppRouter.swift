import Foundation
import Observation

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
    /// Bumped on every "show the Transactions list" deep-link so the Transactions
    /// stack pops any pushed detail back to the (filtered) root.
    private(set) var resetToken = UUID()

    init(selectedTab: Int = 0) {
        self.selectedTab = selectedTab
    }

    /// Switch to a filtered Transactions list (root), clearing any pushed detail.
    func showTransactions(_ filter: TransactionFilter) {
        txnFilter = filter
        pendingTxnID = nil
        resetToken = UUID()
        selectedTab = 2
    }

    /// Switch to the Transactions tab and open one transaction's detail.
    func openTransaction(id: String) {
        txnFilter = .all
        pendingTxnID = id
        selectedTab = 2
    }
}
