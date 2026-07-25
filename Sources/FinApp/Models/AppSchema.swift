import Foundation
import SwiftData

/// Central list of persisted model types. One place to update when models change.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Account.self,
        Transaction.self,
        Category.self,
        CategoryRule.self,
        Budget.self,
        RecurringBill.self,
        NetWorthSnapshot.self,
        AccountBalanceSnapshot.self,
    ]

    /// Shared on-disk container for the app.
    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// Ephemeral in-memory container for tests and previews.
    @MainActor
    static func makeInMemoryContainer() -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
