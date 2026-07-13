import Foundation

/// Infers an `AccountType` from a SimpleFin account's name and balance.
/// SimpleFin provides no type field, so this keyword heuristic runs once when
/// a synced account is first inserted; the user can reclassify afterwards and
/// sync never overwrites the type.
enum AccountTypeDetector {
    /// Checked in order, first match wins — loan before creditCard so
    /// "Car Loan" isn't a card; investment before creditCard so branded
    /// investment cards err toward investment.
    private static let rules: [(type: AccountType, keywords: [String])] = [
        (.loan, ["loan", "mortgage", "heloc"]),
        (.investment, ["brokerage", "invest", "401k", "401(k)", "ira", "roth",
                       "hsa", "529", "mutual", "stock", "crypto", "retirement"]),
        (.creditCard, ["credit", "visa", "mastercard", "amex", "card"]),
        (.cash, ["checking", "chequing", "savings", "saving", "cash", "money market"]),
    ]

    /// Short tokens that false-positive inside common words ("admiral"
    /// contains "ira") — matched as whole words only.
    private static let wholeWordTokens: Set<String> = ["ira", "hsa"]

    static func infer(name: String, balance: Decimal) -> AccountType {
        let lowered = name.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        for rule in rules {
            for keyword in rule.keywords {
                let matches = wholeWordTokens.contains(keyword)
                    ? words.contains(Substring(keyword))
                    : lowered.contains(keyword)
                if matches { return rule.type }
            }
        }
        return balance < 0 ? .creditCard : .cash
    }
}
