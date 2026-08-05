import Foundation
import SwiftData

/// Assigns categories to transactions from ordered keyword rules, and learns
/// new rules from manual overrides. Matching logic is pure and unit-tested.
enum CategorizationEngine {
    /// Lowest `priority` value wins among matching rules. A matching exclusion
    /// rule (nil category) suppresses seed rules — the transaction stays
    /// uncategorized — but a matching user rule outranks the exclusion: an
    /// explicit user choice always wins.
    static func bestCategory(forMatchText text: String, rules: [CategoryRule]) -> Category? {
        let match = evaluate(text, rules: rules)
        guard let best = match.best else { return nil }
        return (best.createdByUser || !match.excluded) ? best.category : nil
    }

    static func isExcluded(_ text: String, rules: [CategoryRule]) -> Bool {
        rules.contains { $0.category == nil && $0.matches(text) }
    }

    /// One pass over the rule table: the winning categorized rule plus whether
    /// an exclusion rule matches.
    private static func evaluate(_ text: String, rules: [CategoryRule])
        -> (best: CategoryRule?, excluded: Bool) {
        var excluded = false
        var best: CategoryRule?
        for rule in rules where rule.matches(text) {
            if rule.category == nil {
                excluded = true
            } else if best == nil || rulePrecedes(rule, best!) {
                best = rule
            }
        }
        return (best, excluded)
    }

    private static func rulePrecedes(_ lhs: CategoryRule, _ rhs: CategoryRule) -> Bool {
        if lhs.createdByUser != rhs.createdByUser { return lhs.createdByUser }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.keyword.count != rhs.keyword.count { return lhs.keyword.count > rhs.keyword.count }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Auto-categorize unless the user has already set the category. An
    /// exclusion (with no user rule) suppresses new categorization but never
    /// strips a category the transaction already has, so shipping an exclusion
    /// keyword leaves existing history intact.
    static func categorize(_ txn: Transaction, using rules: [CategoryRule]) {
        guard !txn.categorizedByUser else { return }
        let match = evaluate(txn.matchText, rules: rules)
        if let best = match.best, best.createdByUser || !match.excluded {
            txn.category = best.category
        } else if !match.excluded {
            txn.category = nil
        }
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
        try? stageCategorizeAll(txns, in: context)
        try? context.save()
    }

    @MainActor
    static func stageCategorizeAll(_ txns: [Transaction], in context: ModelContext) throws {
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        guard !rules.isEmpty else { return }
        for txn in txns where !txn.categorizedByUser {
            categorize(txn, using: rules)
        }
    }

    /// Apply a manual override and remember it as a high-priority user rule so
    /// future transactions from the same merchant categorize automatically.
    @MainActor
    @discardableResult
    static func learn(from txn: Transaction, category: Category, in context: ModelContext) -> CategoryRule {
        txn.category = category
        txn.categorizedByUser = true

        let keyword = normalizeMerchant(txn.payee ?? txn.detail)
        let matches = ((try? context.fetch(FetchDescriptor<CategoryRule>())) ?? [])
            .filter { $0.createdByUser && $0.keyword == keyword }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let rule: CategoryRule
        if let existing = matches.first {
            existing.priority = 0
            existing.category = category
            for duplicate in matches.dropFirst() { context.delete(duplicate) }
            rule = existing
        } else {
            rule = CategoryRule(keyword: keyword, priority: 0, createdByUser: true, category: category)
            context.insert(rule)
        }
        return rule
    }

    /// Apply one rule to every transaction it matches (skipping user-set ones).
    /// Used after `learn` so a manual assignment reaches the merchant's other
    /// charges without re-running every rule against the whole store. Learned
    /// rules are user rules, which outrank exclusions, so no exclusion check.
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

    /// Ranked category suggestions for a merchant's match text: matching rules
    /// first (user-learned rules outrank seeds), then the categories used most
    /// across `transactions`. Confidence is a display heuristic for the picker
    /// ("92% match"), not a probability.
    static func suggestions(forMatchText text: String, rules: [CategoryRule],
                            transactions: [Transaction], limit: Int = 2)
        -> [(category: Category, confidence: Double)] {
        var out: [(category: Category, confidence: Double)] = []
        var seen = Set<String>()

        // Excluded merchants suggest only user rules (which outrank the
        // exclusion) — offering a seed rule's category would undo the
        // exclusion one accept at a time.
        let excluded = isExcluded(text, rules: rules)
        let matching = rules
            .filter { $0.category != nil && $0.matches(text) && (!excluded || $0.createdByUser) }
            .sorted(by: rulePrecedes)
        for rule in matching {
            guard let category = rule.category, !seen.contains(category.name) else { continue }
            seen.insert(category.name)
            out.append((category, rule.createdByUser ? 0.95 : 0.92))
            if out.count == limit { return out }
        }

        // No most-used fallback for excluded merchants: filing a transfer
        // under a guessed spending category would miscount it as spending.
        if excluded { return out }

        // Fallback: the user's most-used spending categories.
        var counts: [String: (category: Category, count: Int)] = [:]
        for txn in transactions {
            guard let category = txn.category, !category.isIncome, category.name != "Transfers" else { continue }
            counts[category.name, default: (category, 0)].count += 1
        }
        for entry in counts.values.sorted(by: { $0.count > $1.count }) {
            guard !seen.contains(entry.category.name) else { continue }
            seen.insert(entry.category.name)
            out.append((entry.category, 0.6))
            if out.count == limit { break }
        }
        return out
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
