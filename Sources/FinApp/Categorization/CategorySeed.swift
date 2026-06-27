import Foundation
import SwiftData

/// Default categories and keyword rules, seeded once on first launch.
enum CategorySeed {
    struct Seed {
        let name: String
        let color: String
        let icon: String
        let isIncome: Bool
        let keywords: [String]
    }

    static let seeds: [Seed] = [
        Seed(name: "Income", color: "#34C759", icon: "dollarsign.circle", isIncome: true,
             keywords: ["payroll", "direct dep", "direct deposit", "deposit", "interest", "dividend", "refund"]),
        Seed(name: "Groceries", color: "#30D158", icon: "cart", isIncome: false,
             keywords: ["grocery", "market", "trader joe", "whole foods", "safeway", "kroger", "costco", "aldi", "wegmans"]),
        Seed(name: "Dining", color: "#FF9500", icon: "fork.knife", isIncome: false,
             keywords: ["restaurant", "coffee", "cafe", "starbucks", "doordash", "uber eats", "ubereats", "grubhub", "mcdonald", "chipotle", "pizza"]),
        Seed(name: "Bars", color: "#BF5AF2", icon: "wineglass", isIncome: false,
             keywords: ["bar", "pub", "brewery", "tavern", "taproom", "liquor", "saloon", "cocktail", "winery"]),
        Seed(name: "Transport", color: "#5856D6", icon: "car", isIncome: false,
             keywords: ["uber", "lyft", "shell", "chevron", "exxon", "gas", "parking", "transit", "bart", "metro", "toll"]),
        Seed(name: "Shopping", color: "#FF2D55", icon: "bag", isIncome: false,
             keywords: ["amazon", "target", "walmart", "ebay", "best buy", "apple store"]),
        Seed(name: "Subscriptions", color: "#AF52DE", icon: "repeat", isIncome: false,
             keywords: ["netflix", "spotify", "hulu", "disney", "youtube", "apple.com/bill", "patreon", "icloud"]),
        Seed(name: "Utilities", color: "#5AC8FA", icon: "bolt", isIncome: false,
             keywords: ["electric", "water", "comcast", "xfinity", "at&t", "verizon", "t-mobile", "pg&e", "utility"]),
        Seed(name: "Housing", color: "#A2845E", icon: "house", isIncome: false,
             keywords: ["rent", "mortgage", "hoa", "property"]),
        Seed(name: "Health", color: "#FF3B30", icon: "cross.case", isIncome: false,
             keywords: ["pharmacy", "cvs", "walgreens", "doctor", "medical", "dental", "clinic"]),
        Seed(name: "Education", color: "#5E5CE6", icon: "graduationcap", isIncome: false,
             keywords: ["tuition", "university", "college", "campus", "udemy", "coursera", "edx", "textbook", "bookstore", "school"]),
        Seed(name: "Travel", color: "#FFCC00", icon: "airplane", isIncome: false,
             keywords: ["airline", "hotel", "airbnb", "delta", "united", "expedia", "marriott", "hilton"]),
        Seed(name: "Entertainment", color: "#FF6482", icon: "theatermasks", isIncome: false,
             keywords: ["cinema", "movie", "theater", "theatre", "amc", "regal", "concert", "ticketmaster", "stubhub", "steam", "playstation", "xbox", "nintendo", "bowling", "arcade", "museum"]),
        Seed(name: "Transfers", color: "#8E8E93", icon: "arrow.left.arrow.right", isIncome: false,
             keywords: ["transfer", "venmo", "zelle", "withdrawal", "atm", "paypal"]),
    ]

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        guard existing.isEmpty else { return }

        for seed in seeds {
            insert(seed, in: context)
        }
        try? context.save()
    }

    /// Idempotently add any seed categories missing from an already-seeded store,
    /// so new defaults (e.g. Bars) reach existing installs.
    @MainActor
    static func ensureMissing(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        guard !existing.isEmpty else { return }
        let names = Set(existing.map(\.name))
        var added = false
        for seed in seeds where !names.contains(seed.name) {
            insert(seed, in: context)
            added = true
        }
        if added { try? context.save() }
    }

    @MainActor
    private static func insert(_ seed: Seed, in context: ModelContext) {
        let category = Category(name: seed.name, colorHex: seed.color, systemIcon: seed.icon, isIncome: seed.isIncome)
        context.insert(category)
        for keyword in seed.keywords {
            context.insert(CategoryRule(keyword: keyword, priority: 100, createdByUser: false, category: category))
        }
    }
}
