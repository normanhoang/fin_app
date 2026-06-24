import XCTest
@testable import FinApp

final class CredentialStoreTests: XCTestCase {
    let store = CredentialStore(service: "com.normanhoang.finapp.tests")

    override func tearDown() {
        store.deleteAccessURL()
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = URL(string: "https://user:pass@bridge.simplefin.org/simplefin")!
        try store.saveAccessURL(url)
        XCTAssertEqual(store.loadAccessURL(), url)
    }

    func testOverwriteExistingValue() throws {
        try store.saveAccessURL(URL(string: "https://a@bridge.simplefin.org/simplefin")!)
        try store.saveAccessURL(URL(string: "https://b@bridge.simplefin.org/simplefin")!)
        XCTAssertEqual(store.loadAccessURL()?.absoluteString, "https://b@bridge.simplefin.org/simplefin")
    }

    func testDeleteRemovesValue() throws {
        try store.saveAccessURL(URL(string: "https://a@bridge.simplefin.org/simplefin")!)
        store.deleteAccessURL()
        XCTAssertNil(store.loadAccessURL())
    }

    func testLoadWhenEmptyReturnsNil() {
        store.deleteAccessURL()
        XCTAssertNil(store.loadAccessURL())
    }
}
