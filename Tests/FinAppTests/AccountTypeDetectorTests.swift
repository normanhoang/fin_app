import XCTest
@testable import FinApp

final class AccountTypeDetectorTests: XCTestCase {
    private func infer(_ name: String, balance: String = "100.00") -> AccountType {
        AccountTypeDetector.infer(name: name, balance: Decimal(string: balance)!)
    }

    // MARK: Keyword groups

    func testLoanKeywords() {
        XCTAssertEqual(infer("Auto Loan"), .loan)
        XCTAssertEqual(infer("Home Mortgage"), .loan)
        XCTAssertEqual(infer("HELOC"), .loan)
    }

    func testInvestmentKeywords() {
        XCTAssertEqual(infer("Brokerage"), .investment)
        XCTAssertEqual(infer("Investment Account"), .investment)
        XCTAssertEqual(infer("401k"), .investment)
        XCTAssertEqual(infer("401(k) Plan"), .investment)
        XCTAssertEqual(infer("Roth IRA"), .investment)
        XCTAssertEqual(infer("HSA"), .investment)
        XCTAssertEqual(infer("529 College Fund"), .investment)
        XCTAssertEqual(infer("Retirement"), .investment)
        XCTAssertEqual(infer("Crypto Wallet"), .investment)
    }

    func testCreditCardKeywords() {
        XCTAssertEqual(infer("Chase Sapphire Credit Card", balance: "-50.00"), .creditCard)
        XCTAssertEqual(infer("Visa Signature"), .creditCard)
        XCTAssertEqual(infer("Mastercard"), .creditCard)
        XCTAssertEqual(infer("Amex Gold"), .creditCard)
    }

    func testCashKeywords() {
        XCTAssertEqual(infer("Everyday Checking"), .cash)
        XCTAssertEqual(infer("Chequing"), .cash)
        XCTAssertEqual(infer("High-Yield Savings"), .cash)
        XCTAssertEqual(infer("Money Market"), .cash)
    }

    // MARK: Precedence

    func testLoanBeatsCreditCard() {
        XCTAssertEqual(infer("Car Loan Card Services", balance: "-5000.00"), .loan)
    }

    func testInvestmentBeatsCreditCard() {
        XCTAssertEqual(infer("Fidelity Rewards Investment Card"), .investment)
    }

    // MARK: Word boundaries

    func testShortTokensMatchWholeWordsOnly() {
        // "admiral" contains "ira"; "chsange" style false positives for "hsa".
        XCTAssertEqual(infer("Admiral Shares Checking"), .cash)
        XCTAssertEqual(infer("Admiral Fund"), .cash)
    }

    // MARK: Fallback

    func testUnknownNegativeBalanceIsCreditCard() {
        XCTAssertEqual(infer("Blue Account", balance: "-42.00"), .creditCard)
    }

    func testUnknownPositiveBalanceIsCash() {
        XCTAssertEqual(infer("Blue Account", balance: "42.00"), .cash)
    }

    // MARK: Case-insensitivity

    func testCaseInsensitive() {
        XCTAssertEqual(infer("SAVINGS"), .cash)
        XCTAssertEqual(infer("visa PLATINUM"), .creditCard)
    }
}
