import Foundation

enum SimpleFinError: Error, LocalizedError {
    case invalidSetupToken
    case claimFailed(status: Int)
    case fetchFailed(status: Int)
    case invalidAccessURL

    var errorDescription: String? {
        switch self {
        case .invalidSetupToken: "That setup token isn't valid. Copy it again from SimpleFin."
        case .claimFailed(let s): "Couldn't claim the SimpleFin token (HTTP \(s))."
        case .fetchFailed(let s): "Couldn't fetch accounts from SimpleFin (HTTP \(s))."
        case .invalidAccessURL: "The stored SimpleFin connection is invalid. Reconnect in Settings."
        }
    }
}

/// Talks to a SimpleFin Bridge. Read-only. The pure helpers (`claimURL`,
/// `accountsURL`) are unit-tested; the URLSession calls are exercised via the
/// manual end-to-end flow with a real token.
struct SimpleFinClient {
    var session: URLSession = .shared

    /// Construct the client. Pass `pinned: true` to require the SimpleFin Bridge
    /// certificate chain to match the pinned CA keys (`CertificatePinner`).
    /// Off by default — enable only after verifying connectivity on-device, since
    /// pinning is fail-closed (see CertificatePinner docs).
    static func live(pinned: Bool = false) -> SimpleFinClient {
        SimpleFinClient(session: pinned ? CertificatePinner.makeSession() : .shared)
    }

    // MARK: Pure helpers

    /// A setup token is base64 that decodes to a one-time claim URL.
    static func claimURL(fromSetupToken token: String) throws -> URL {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = Data(base64Encoded: trimmed),
            let string = String(data: data, encoding: .utf8),
            let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme == "https"
        else { throw SimpleFinError.invalidSetupToken }
        return url
    }

    static func accountsURL(accessURL: URL, since: Date?) -> URL {
        let base = accessURL.appending(path: "accounts")
        guard let since else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "start-date", value: String(Int(since.timeIntervalSince1970)))]
        return comps.url ?? base
    }

    /// HTTP Basic `Authorization` header value from credentials embedded in the
    /// access URL. URLSession does not send URL-embedded credentials unless the
    /// server issues a 401 challenge; SimpleFin Bridge returns 403 instead, so we
    /// must attach the header ourselves.
    static func basicAuthHeader(for url: URL) -> String? {
        guard let user = url.user(percentEncoded: false),
              let password = url.password(percentEncoded: false) else { return nil }
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    /// The same URL with any embedded credentials stripped, so they aren't
    /// duplicated in the request line once moved to the `Authorization` header.
    static func requestURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.user = nil
        comps.password = nil
        return comps.url ?? url
    }

    // MARK: Network

    /// Exchanges a setup token for a long-lived access URL.
    func claim(setupToken: String) async throws -> URL {
        let url = try Self.claimURL(fromSetupToken: setupToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SimpleFinError.claimFailed(status: status) }

        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accessURL = URL(string: body), accessURL.scheme == "https" else {
            throw SimpleFinError.invalidAccessURL
        }
        return accessURL
    }

    /// Fetches accounts + transactions, optionally only those posted since `since`.
    func fetchAccounts(accessURL: URL, since: Date? = nil) async throws -> SimpleFinResponse {
        let url = Self.accountsURL(accessURL: accessURL, since: since)
        var request = URLRequest(url: Self.requestURL(url))
        if let auth = Self.basicAuthHeader(for: url) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SimpleFinError.fetchFailed(status: status) }
        return try SimpleFinResponse.decode(from: data)
    }
}
