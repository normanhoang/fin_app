import XCTest
import Security
@testable import FinApp

final class CertificatePinnerTests: XCTestCase {
    // Decision logic ---------------------------------------------------------

    func testTrustedWhenChainContainsPinnedHash() {
        let pinned: Set<String> = ["A", "B"]
        XCTAssertTrue(CertificatePinner.isTrusted(chainSPKIHashes: ["leaf", "B"], pinned: pinned))
    }

    func testRejectedWhenNoChainHashMatches() {
        let pinned: Set<String> = ["A", "B"]
        XCTAssertFalse(CertificatePinner.isTrusted(chainSPKIHashes: ["leaf", "intermediate"], pinned: pinned))
    }

    func testRejectedOnEmptyChain() {
        XCTAssertFalse(CertificatePinner.isTrusted(chainSPKIHashes: [], pinned: ["A"]))
    }

    // Real SPKI extraction ---------------------------------------------------
    // Google Trust Services "WE1" intermediate (EC P-256), captured 2026-06-23.
    // Asserts spkiSHA256Base64 reproduces the pin derived independently via
    // `openssl x509 | openssl pkey -pubin -outform der | openssl dgst -sha256`.
    private let we1DERBase64 = "MIICnzCCAiWgAwIBAgIQf/MZd5csIkp2FV0TttaF4zAKBggqhkjOPQQDAzBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjQwHhcNMjMxMjEzMDkwMDAwWhcNMjkwMjIwMTQwMDAwWjA7MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVR29vZ2xlIFRydXN0IFNlcnZpY2VzMQwwCgYDVQQDEwNXRTEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARvzTr+Z1dHTCEDhUDCR127WEcPQMFcF4XGGTfn1XzthkubgdnXGhOlCgP4mMTG6J7/EFmPLCaY9eYmJbsPAvpWo4H+MIH7MA4GA1UdDwEB/wQEAwIBhjAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUkHeSNWfE/6jMqeZ72YB5e8yT+TgwHwYDVR0jBBgwFoAUgEzW63T/STaj1dj8tT7FavCUHYwwNAYIKwYBBQUHAQEEKDAmMCQGCCsGAQUFBzAChhhodHRwOi8vaS5wa2kuZ29vZy9yNC5jcnQwKwYDVR0fBCQwIjAgoB6gHIYaaHR0cDovL2MucGtpLmdvb2cvci9yNC5jcmwwEwYDVR0gBAwwCjAIBgZngQwBAgEwCgYIKoZIzj0EAwMDaAAwZQIxAOcCq1HW90OVznX+0RGU1cxAQXomvtgM8zItPZCuFQ8jSBJSjz5keROv9aYsAm5VsQIwJonMaAFi54mrfhfoFNZEfuNMSQ6/bIBiNLiyoX46FohQvKeIoJ99cx7sUkFN7uJW"

    func testSPKIHashMatchesIndependentlyDerivedPin() throws {
        let der = try XCTUnwrap(Data(base64Encoded: we1DERBase64))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let pin = CertificatePinner.spkiSHA256Base64(for: cert)
        XCTAssertEqual(pin, "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=")
        XCTAssertTrue(CertificatePinner.pinnedSPKISHA256.contains(pin ?? ""))
    }
}
