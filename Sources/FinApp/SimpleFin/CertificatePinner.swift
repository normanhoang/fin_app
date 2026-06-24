import Foundation
import CryptoKit

/// SPKI public-key pinning for SimpleFin Bridge.
///
/// Pins the **intermediate + root** public keys (not the leaf): the leaf cert
/// rotates roughly every 90 days, while the CA keys are stable for years. This
/// closes the "trusted-but-rogue CA / MITM proxy" gap that ATS alone does not.
///
/// SHIPPED OFF BY DEFAULT. Pinning is fail-closed: if SimpleFin migrates CAs and
/// these pins drift, the app loses connectivity. Enable only after verifying on a
/// real device against a live token (see the audit remediation notes), then flip
/// `SimpleFinClient`'s session to `CertificatePinner.makeSession()`.
///
/// Pins captured 2026-06-23 from bridge.simplefin.org and beta-bridge.simplefin.org
/// (identical chains): Google Trust Services "WE1" (EC P-256) + "GTS Root R4" (EC P-384).
final class CertificatePinner: NSObject, URLSessionDelegate {
    static let pinnedSPKISHA256: Set<String> = [
        "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=", // Google Trust Services WE1 (intermediate)
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=", // GTS Root R4 (root)
    ]

    /// Hosts the pin set applies to. Other hosts fall through to default trust.
    static let pinnedHostSuffix = "simplefin.org"

    static func makeSession() -> URLSession {
        URLSession(configuration: .default, delegate: CertificatePinner(), delegateQueue: nil)
    }

    /// Pure decision: trusted if any cert in the chain matches a pinned SPKI hash.
    static func isTrusted(chainSPKIHashes: [String], pinned: Set<String>) -> Bool {
        chainSPKIHashes.contains { pinned.contains($0) }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Only pin our own backend; everything else uses system trust.
        guard challenge.protectionSpace.host.hasSuffix(Self.pinnedHostSuffix) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Standard chain validation (expiry, hostname, trusted root).
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 2. Pin check against the chain's SPKI hashes.
        let hashes = Self.chainSPKIHashes(for: trust)
        if Self.isTrusted(chainSPKIHashes: hashes, pinned: Self.pinnedSPKISHA256) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: SPKI extraction

    private static func chainSPKIHashes(for trust: SecTrust) -> [String] {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return chain.compactMap { spkiSHA256Base64(for: $0) }
    }

    /// SHA-256 of the certificate's DER SubjectPublicKeyInfo, base64-encoded —
    /// matching `openssl x509 | openssl pkey -pubin -outform der | dgst -sha256`.
    static func spkiSHA256Base64(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let header = asn1Header(for: attrs) else { return nil }
        let spki = header + raw
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// Fixed ASN.1 SubjectPublicKeyInfo prefixes by key type/size. `SecKeyCopyExternalRepresentation`
    /// returns the bare key (X9.63 point for EC, PKCS#1 for RSA); prepending the matching
    /// header reconstructs the full SPKI DER that the pin hashes.
    private static func asn1Header(for attrs: [CFString: Any]) -> Data? {
        guard let type = attrs[kSecAttrKeyType] as? String,
              let bits = attrs[kSecAttrKeySizeInBits] as? Int else { return nil }

        let isEC = type == (kSecAttrKeyTypeECSECPrimeRandom as String)
        let isRSA = type == (kSecAttrKeyTypeRSA as String)

        if isEC && bits == 256 {
            return Data([0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
                         0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00])
        }
        if isEC && bits == 384 {
            return Data([0x30,0x76,0x30,0x10,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
                         0x06,0x05,0x2b,0x81,0x04,0x00,0x22,0x03,0x62,0x00,0x04])
        }
        if isRSA && bits == 2048 {
            return Data([0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,
                         0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00])
        }
        if isRSA && bits == 4096 {
            return Data([0x30,0x82,0x02,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,
                         0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x02,0x0f,0x00])
        }
        return nil
    }
}
