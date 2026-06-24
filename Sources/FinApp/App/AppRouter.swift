import Foundation
import Observation

/// Active filter applied to the Transactions list, set when the user drills in
/// from the Dashboard.
enum TransactionFilter: Equatable {
    case all
    case income
    case spending
    case category(String)
}

/// App-level navigation state shared across tabs so the Dashboard can deep-link
/// into a pre-filtered Transactions tab.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: Int
    var txnFilter: TransactionFilter = .all

    init(selectedTab: Int = 0) {
        self.selectedTab = selectedTab
    }
}
