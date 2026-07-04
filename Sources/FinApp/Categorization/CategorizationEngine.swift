import Foundation
import SwiftData

/// Assigns categories to transactions from ordered keyword rules, and learns
/// new rules from manual overrides. Matching logic is pure and unit-tested.
enum CategorizationEngine {
    /// Lowest `priority` value wins among matching rules.
    static func bestCategory(forMatchText text: String, rules: [CategoryRule]) -> Category? {
        rules
            .filter { $0.category != nil && $0.matches(text) }
            .min { $0.priority < $1.priority }?
            .category
    }

    /// Auto-categorize unless the user has already set the category.
    static func categorize(_ txn: Transaction, using rules: [CategoryRule]) {
        guard !txn.categorizedByUser else { return }
        txn.category = bestCategory(forMatchText: txn.matchText, rules: rules)
    }

    /// Categorize every transaction not yet categorized by the user. Filters in
    /// memory rather than via `#Predicate` (SwiftData predicate fetches trap on
    /// this toolchain).
    @MainActor
    static func categorizeAll(in context: ModelContext) {
        let txns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        categorizeAll(txns, in: context)
    }

    /// Same, over an already-fetched transaction list so the sync pipeline can
    /// share one fetch across its post-sync steps.
    @MainActor
    static func categorizeAll(_ txns: [Transaction], in context: ModelContext) {
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        guard !rules.isEmpty else { return }
        for txn in txns where !txn.categorizedByUser {
            categorize(txn, using: rules)
        }
        try? context.save()
    }

    /// Apply a manual override and remember it as a high-priority user rule so
    /// future transactions from the same merchant categorize automatically.
    @MainActor
    @discardableResult
    static func learn(from txn: Transaction, category: Category, in context: ModelContext) -> CategoryRule {
        txn.category = category
        txn.categorizedByUser = true

        let keyword = normalizeMerchant(txn.payee ?? txn.detail)
        let rule = CategoryRule(keyword: keyword, priority: 0, createdByUser: true, category: category)
        context.insert(rule)
        return rule
    }

    /// Apply one rule to every transaction it matches (skipping user-set ones).
    /// Used after `learn` so a manual assignment reaches the merchant's other
    /// charges without re-running every rule against the whole store.
    @MainActor
    static func apply(_ rule: CategoryRule, in context: ModelContext) {
        let txns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for txn in txns where !txn.categorizedByUser && rule.matches(txn.matchText) {
            txn.category = rule.category
        }
        try? context.save()
    }

    /// Assign (or clear) a transaction's category from a user action. A non-nil
    /// category learns a rule and applies just that rule to the merchant's other
    /// charges; nil clears the category and protects it from auto-recategorizing.
    @MainActor
    static func assign(_ category: Category?, to txn: Transaction, in context: ModelContext) {
        if let category {
            let rule = learn(from: txn, category: category, in: context)
            apply(rule, in: context)
        } else {
            txn.category = nil
            txn.categorizedByUser = true
            try? context.save()
        }
    }

    /// Lowercase and drop tokens that contain digits or punctuation noise, so
    /// "COFFEE SHOP #42" and "COFFEE SHOP #99" collapse to "coffee shop".
    static func normalizeMerchant(_ raw: String) -> String {
        raw
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "#" })
            .filter { token in !token.contains(where: { $0.isNumber }) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
