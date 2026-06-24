import Foundation

/// Classifies an account into an asset/debt group for the Accounts screen.
/// SimpleFin provides no type, so synced accounts default to `.cash` and the
/// user can reclassify; manual accounts pick a type on creation.
enum AccountType: String, CaseIterable, Identifiable {
    case cash
    case investment
    case property
    case creditCard
    case loan
    case other

    var id: String { rawValue }

    var isDebt: Bool {
        switch self {
        case .creditCard, .loan: true
        default: false
        }
    }

    /// Top-level section on the Accounts screen.
    var groupTitle: String { isDebt ? "Debts" : "Assets" }

    /// Subsection label within the group.
    var displayName: String {
        switch self {
        case .cash: "Cash"
        case .investment: "Investments"
        case .property: "Property"
        case .creditCard: "Credit Cards"
        case .loan: "Loans"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .cash: "banknote"
        case .investment: "chart.line.uptrend.xyaxis"
        case .property: "house"
        case .creditCard: "creditcard"
        case .loan: "doc.text"
        case .other: "square.stack"
        }
    }

    /// Display order within the Accounts list (assets first, then debts).
    var sortIndex: Int {
        switch self {
        case .cash: 0
        case .investment: 1
        case .property: 2
        case .other: 3
        case .creditCard: 4
        case .loan: 5
        }
    }
}
