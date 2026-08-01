import Foundation

/// Decoded SimpleFin `/accounts` response. Pure value types, no persistence —
/// the boundary between the network and the SwiftData store.
struct SimpleFinResponse: Decodable {
    var errors: [String]
    var accounts: [AccountDTO]

    static func decode(from data: Data) throws -> SimpleFinResponse {
        try JSONDecoder().decode(SimpleFinResponse.self, from: data)
    }
}

struct AccountDTO: Decodable {
    var id: String
    var providerScope: String
    var org: String
    var name: String
    var currency: String
    var balance: Decimal
    var availableBalance: Decimal?
    var balanceDate: Date
    var transactions: [TransactionDTO]

    private enum CodingKeys: String, CodingKey {
        case id, org, name, currency, balance, transactions
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }

    private enum OrgKeys: String, CodingKey {
        case name, domain
        case sfinURL = "sfin-url"
    }

    init(
        id: String, providerScope: String, org: String, name: String, currency: String,
        balance: Decimal, availableBalance: Decimal?, balanceDate: Date,
        transactions: [TransactionDTO]
    ) {
        self.id = id
        self.providerScope = providerScope
        self.org = org
        self.name = name
        self.currency = currency
        self.balance = balance
        self.availableBalance = availableBalance
        self.balanceDate = balanceDate
        self.transactions = transactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        currency = try c.decode(String.self, forKey: .currency)
        balance = try Self.decimal(c, .balance)
        availableBalance = try Self.decimalIfPresent(c, .availableBalance)
        balanceDate = Date(timeIntervalSince1970: try c.decode(TimeInterval.self, forKey: .balanceDate))
        transactions = try c.decodeIfPresent([TransactionDTO].self, forKey: .transactions) ?? []

        // Account IDs are scoped to the organization. Names are display values
        // and may change, so identity requires a stable URL or domain.
        let org = try c.nestedContainer(keyedBy: OrgKeys.self, forKey: .org)
        let orgName = try org.decodeIfPresent(String.self, forKey: .name)
        let domain = try org.decodeIfPresent(String.self, forKey: .domain)
        let sfinURL = try org.decodeIfPresent(String.self, forKey: .sfinURL)
        self.org = orgName ?? domain ?? "Unknown"
        // Prefer a stable URL/domain; fall back to the display name (or a fixed
        // sentinel) rather than failing the whole response over one odd org.
        providerScope = sfinURL ?? domain ?? orgName ?? "unknown-org"
    }

    private static func decimal(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Decimal {
        let str = try c.decode(String.self, forKey: key)
        guard let value = Decimal(string: str) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not a decimal: \(str)")
        }
        return value
    }

    private static func decimalIfPresent(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Decimal? {
        guard let str = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return Decimal(string: str)
    }
}

struct TransactionDTO: Decodable {
    var id: String
    var posted: Date
    var amount: Decimal
    var detail: String
    var payee: String?
    var memo: String?
    var pending: Bool

    private enum CodingKeys: String, CodingKey {
        case id, posted, amount, payee, memo, pending
        case detail = "description"
        case transactedAt = "transacted_at"
    }

    init(
        id: String, posted: Date, amount: Decimal, detail: String,
        payee: String?, memo: String?, pending: Bool
    ) {
        self.id = id
        self.posted = posted
        self.amount = amount
        self.detail = detail
        self.payee = payee
        self.memo = memo
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Pending transactions may carry posted=0 or null, with the real date in
        // transacted_at.
        let postedRaw = try c.decodeIfPresent(TimeInterval.self, forKey: .posted)
        let transactedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .transactedAt)
        if let postedRaw, postedRaw > 0 {
            posted = Date(timeIntervalSince1970: postedRaw)
        } else if let transactedAt {
            posted = Date(timeIntervalSince1970: transactedAt)
        } else if let postedRaw {
            posted = Date(timeIntervalSince1970: postedRaw)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.posted,
                .init(codingPath: c.codingPath,
                      debugDescription: "Transaction has neither posted nor transacted_at")
            )
        }
        let amountStr = try c.decode(String.self, forKey: .amount)
        guard let amount = Decimal(string: amountStr) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: c, debugDescription: "Not a decimal: \(amountStr)")
        }
        self.amount = amount
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        payee = try c.decodeIfPresent(String.self, forKey: .payee)
        memo = try c.decodeIfPresent(String.self, forKey: .memo)
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}
