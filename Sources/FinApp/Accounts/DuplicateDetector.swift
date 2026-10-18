import Foundation

/// A likely duplicate pair: `flaggedID` is the account suggested for deletion
/// (the badge goes on it), `matchID` the one it duplicates.
struct DuplicateSuggestion: Equatable, Identifiable {
    let flaggedID: String
    let matchID: String
    var id: String { flaggedID }
}

/// Spots accounts that probably track the same thing (e.g. an old manual
/// "Mortgage" next to a new scheduled "Mortgage (Auto)"). Pure over its inputs,
/// so the UI re-evaluates it whenever accounts change — covering manual adds,
/// SimpleFin sync and FinanceKit imports alike.
enum DuplicateDetector {
    static let balanceTolerance: Decimal = 0.05
    private static let stopwords: Set<String> = ["the", "and", "account", "manual", "old", "new"]

    /// Order-independent key for a pair, used to persist dismissals.
    static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// Same type, at least one manual (SimpleFin dedupes itself; FinanceKit ↔
    /// SimpleFin is `FinanceKitMerge`'s job), and close balances or overlapping names.
    static func isLikelyDuplicate(_ a: Account, _ b: Account) -> Bool {
        guard a.id != b.id, a.accountType == b.accountType,
              a.source == .manual || b.source == .manual else { return false }
        return balancesClose(a.balance, b.balance) || namesOverlap(a.displayName, b.displayName)
    }

    static func firstSnapshotDays(_ snapshots: [AccountBalanceSnapshot]) -> [String: Date] {
        snapshots.reduce(into: [:]) { days, s in
            if let d = days[s.accountId], d <= s.day { return }
            days[s.accountId] = s.day
        }
    }

    /// At most one suggestion per flagged account (closest-balance match),
    /// sorted by `flaggedID`.
    static func suggestions(accounts: [Account], firstSnapshotDay: [String: Date],
                            dismissed: Set<String>) -> [DuplicateSuggestion] {
        var best: [String: (match: Account, gap: Decimal)] = [:]
        for (i, a) in accounts.enumerated() {
            for b in accounts[(i + 1)...] where isLikelyDuplicate(a, b)
                && !dismissed.contains(pairKey(a.id, b.id)) {
                let (flagged, match) = flaggedFirst(a, b, firstSnapshotDay)
                let gap = balanceGap(a, b)
                if let current = best[flagged.id],
                   (current.gap, current.match.id) <= (gap, match.id) { continue }
                best[flagged.id] = (match, gap)
            }
        }
        return best.map { DuplicateSuggestion(flaggedID: $0.key, matchID: $0.value.match.id) }
            .sorted { $0.flaggedID < $1.flaggedID }
    }

    /// Other accounts of the same type, closest balance first (the sheet's list).
    static func candidates(for account: Account, among accounts: [Account]) -> [Account] {
        accounts.filter { $0.id != account.id && $0.accountType == account.accountType }
            .sorted { (balanceGap(account, $0), $0.id) < (balanceGap(account, $1), $1.id) }
    }

    // MARK: Rules

    private static func balancesClose(_ a: Decimal, _ b: Decimal) -> Bool {
        let x = a.magnitude, y = b.magnitude
        guard x != 0, y != 0 else { return false }
        return (x - y).magnitude <= balanceTolerance * max(x, y)
    }

    private static func namesOverlap(_ a: String, _ b: String) -> Bool {
        let x = significantWords(a), y = significantWords(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.isSubset(of: y) || y.isSubset(of: x)
    }

    private static func significantWords(_ name: String) -> Set<String> {
        Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static func balanceGap(_ a: Account, _ b: Account) -> Decimal {
        (a.balance.magnitude - b.balance.magnitude).magnitude
    }

    /// Manual over non-manual; otherwise the older (earliest snapshot; none =
    /// newest); tie → smaller id.
    private static func flaggedFirst(_ a: Account, _ b: Account,
                                     _ firstDay: [String: Date]) -> (Account, Account) {
        if (a.source == .manual) != (b.source == .manual) {
            return a.source == .manual ? (a, b) : (b, a)
        }
        let da = firstDay[a.id] ?? .distantFuture, db = firstDay[b.id] ?? .distantFuture
        if da != db { return da < db ? (a, b) : (b, a) }
        return a.id < b.id ? (a, b) : (b, a)
    }
}
