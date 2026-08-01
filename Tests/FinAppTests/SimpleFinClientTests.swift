import XCTest
@testable import FinApp

final class SimpleFinClientTests: XCTestCase {
    func testDecodesClaimURLFromBase64SetupToken() throws {
        let claimURL = "https://bridge.simplefin.org/simplefin/claim/demo123"
        let setupToken = Data(claimURL.utf8).base64EncodedString()

        let url = try SimpleFinClient.claimURL(fromSetupToken: setupToken)

        XCTAssertEqual(url.absoluteString, claimURL)
    }

    func testRejectsGarbageSetupToken() {
        XCTAssertThrowsError(try SimpleFinClient.claimURL(fromSetupToken: "!!!not base64!!!"))
    }

    func testBuildsAccountsURLWithStartDate() throws {
        let access = URL(string: "https://user:pass@bridge.simplefin.org/simplefin")!
        let since = Date(timeIntervalSince1970: 1_700_000_000)

        let url = SimpleFinClient.accountsURL(accessURL: access, since: since)

        XCTAssertTrue(url.absoluteString.hasPrefix("https://user:pass@bridge.simplefin.org/simplefin/accounts"))
        XCTAssertTrue(url.absoluteString.contains("start-date=1700000000"))
        XCTAssertTrue(url.absoluteString.contains("pending=1"))
    }

    func testBuildsAccountsURLWithoutStartDate() throws {
        let access = URL(string: "https://user:pass@bridge.simplefin.org/simplefin")!
        let url = SimpleFinClient.accountsURL(accessURL: access, since: nil)
        XCTAssertEqual(url.absoluteString, "https://user:pass@bridge.simplefin.org/simplefin/accounts?pending=1")
    }

    func testBuildsBasicAuthHeaderFromEmbeddedCredentials() throws {
        let access = URL(string: "https://user:pass@bridge.simplefin.org/simplefin")!
        let header = SimpleFinClient.basicAuthHeader(for: access)
        let expected = "Basic " + Data("user:pass".utf8).base64EncodedString()
        XCTAssertEqual(header, expected)
    }

    func testBasicAuthHeaderDecodesPercentEncodedCredentials() throws {
        // SimpleFin access URLs percent-encode special chars in the credentials.
        let access = URL(string: "https://us%40er:p%3Ass@bridge.simplefin.org/simplefin")!
        let header = SimpleFinClient.basicAuthHeader(for: access)
        let expected = "Basic " + Data("us@er:p:ss".utf8).base64EncodedString()
        XCTAssertEqual(header, expected)
    }

    func testBasicAuthHeaderNilWhenNoCredentials() throws {
        let access = URL(string: "https://bridge.simplefin.org/simplefin")!
        XCTAssertNil(SimpleFinClient.basicAuthHeader(for: access))
    }

    func testRequestURLStripsCredentials() throws {
        let access = URL(string: "https://user:pass@bridge.simplefin.org/simplefin/accounts")!
        let url = SimpleFinClient.requestURL(access)
        XCTAssertEqual(url.absoluteString, "https://bridge.simplefin.org/simplefin/accounts")
    }
}
