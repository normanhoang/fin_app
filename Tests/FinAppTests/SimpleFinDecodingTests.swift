import XCTest
@testable import FinApp

final class SimpleFinDecodingTests: XCTestCase {
    let fixture = """
    {
      "errors": ["Connection to MyBank may need attention"],
      "accounts": [
        {
          "org": { "domain": "mybank.com", "name": "My Bank" },
          "id": "acct-123",
          "name": "Checking",
          "currency": "USD",
          "balance": "1234.56",
          "available-balance": "1200.00",
          "balance-date": 1718000000,
          "transactions": [
            {
              "id": "tx-1",
              "posted": 1717900000,
              "amount": "-42.10",
              "description": "COFFEE SHOP #42",
              "payee": "Coffee Shop",
              "memo": "",
              "pending": false
            },
            {
              "id": "tx-2",
              "posted": 1717800000,
              "amount": "2000.00",
              "description": "PAYROLL",
              "pending": true
            }
          ]
        }
      ]
    }
    """

    func testDecodesAccountsAndErrors() throws {
        let data = Data(fixture.utf8)
        let response = try SimpleFinResponse.decode(from: data)

        XCTAssertEqual(response.errors, ["Connection to MyBank may need attention"])
        XCTAssertEqual(response.accounts.count, 1)

        let acct = response.accounts[0]
        XCTAssertEqual(acct.id, "acct-123")
        XCTAssertEqual(acct.providerScope, "mybank.com")
        XCTAssertEqual(acct.org, "My Bank")
        XCTAssertEqual(acct.name, "Checking")
        XCTAssertEqual(acct.currency, "USD")
        XCTAssertEqual(acct.balance, Decimal(string: "1234.56"))
        XCTAssertEqual(acct.availableBalance, Decimal(string: "1200.00"))
        XCTAssertEqual(acct.balanceDate, Date(timeIntervalSince1970: 1718000000))
        XCTAssertEqual(acct.transactions.count, 2)
    }

    func testDecodesTransactionFields() throws {
        let response = try SimpleFinResponse.decode(from: Data(fixture.utf8))
        let txns = response.accounts[0].transactions

        let coffee = txns[0]
        XCTAssertEqual(coffee.id, "tx-1")
        XCTAssertEqual(coffee.amount, Decimal(string: "-42.10"))
        XCTAssertEqual(coffee.detail, "COFFEE SHOP #42")
        XCTAssertEqual(coffee.payee, "Coffee Shop")
        XCTAssertEqual(coffee.posted, Date(timeIntervalSince1970: 1717900000))
        XCTAssertFalse(coffee.pending)

        let payroll = txns[1]
        XCTAssertEqual(payroll.amount, Decimal(string: "2000.00"))
        XCTAssertNil(payroll.payee)
        XCTAssertTrue(payroll.pending)
    }

    func testOrgWithOnlyNameFallsBackToNameForScope() throws {
        // Some bridges omit sfin-url and domain. One odd org must not fail the
        // whole response — fall back to the display name for scope.
        let data = Data("""
        {
          "errors": [],
          "accounts": [{
            "org": { "name": "Mutable Display Name" },
            "id": "acct-123", "name": "Checking", "currency": "USD",
            "balance": "1.00", "balance-date": 1718000000, "transactions": []
          }]
        }
        """.utf8)

        let response = try SimpleFinResponse.decode(from: data)
        XCTAssertEqual(response.accounts.count, 1)
        XCTAssertEqual(response.accounts[0].org, "Mutable Display Name")
        XCTAssertEqual(response.accounts[0].providerScope, "Mutable Display Name")
    }

    func testPendingTransactionUsesTransactedAtWhenPostedZero() throws {
        let data = Data("""
        {
          "errors": [],
          "accounts": [{
            "org": { "domain": "mybank.com" },
            "id": "acct-123", "name": "Checking", "currency": "USD",
            "balance": "1.00", "balance-date": 1718000000,
            "transactions": [{
              "id": "tx-p", "posted": 0, "transacted_at": 1717900000,
              "amount": "-5.00", "description": "HOLD", "pending": true
            }]
          }]
        }
        """.utf8)

        let response = try SimpleFinResponse.decode(from: data)
        XCTAssertEqual(response.accounts[0].transactions[0].posted,
                       Date(timeIntervalSince1970: 1717900000))
    }

    func testPendingTransactionUsesTransactedAtWhenPostedNull() throws {
        let data = Data("""
        {
          "errors": [],
          "accounts": [{
            "org": { "domain": "mybank.com" },
            "id": "acct-123", "name": "Checking", "currency": "USD",
            "balance": "1.00", "balance-date": 1718000000,
            "transactions": [{
              "id": "tx-p", "posted": null, "transacted_at": 1717900000,
              "amount": "-5.00", "description": "HOLD", "pending": true
            }]
          }]
        }
        """.utf8)

        let response = try SimpleFinResponse.decode(from: data)
        XCTAssertEqual(response.accounts[0].transactions[0].posted,
                       Date(timeIntervalSince1970: 1717900000))
    }
}
