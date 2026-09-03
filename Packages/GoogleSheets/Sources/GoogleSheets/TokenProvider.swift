import Foundation

/// An access token and when it stops being usable.
struct AccessToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date

    /// §4.1 caches "until 5 min before expiry" — early enough that a token cannot
    /// expire between being handed out and being used.
    static let refreshMargin: TimeInterval = 300

    func isUsable(at now: Date) -> Bool {
        now < expiresAt - Self.refreshMargin
    }
}

/// Exchanges the signed assertion for an access token, and hands the same token
/// to every caller until it is close to expiring (§4.1).
///
/// An actor because the alternative is a thundering herd: a sync run fires
/// several requests at once, and without serialising, each would mint its own
/// assertion and burn a token exchange. In-flight requests are shared, so N
/// concurrent callers cause one round trip, not N.
public actor GoogleTokenProvider {
    private let account: ServiceAccount
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    private var cached: AccessToken?
    private var inFlight: Task<AccessToken, Error>?

    /// Round trips performed. Exposed so tests can assert the cache actually
    /// prevents work rather than merely returning the right string.
    public private(set) var exchangeCount = 0

    public init(
        account: ServiceAccount,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.transport = transport
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, cached.isUsable(at: now()) { return cached.value }

        if let inFlight { return try await inFlight.value.value }

        let task = Task { try await exchange() }
        inFlight = task
        defer { inFlight = nil }

        let token = try await task.value
        cached = token
        return token.value
    }

    /// Drops the cached token so the next call mints a fresh one. Called on a 401,
    /// which is how a revoked key or a clock jump shows up mid-session (§4.1).
    public func invalidate() {
        cached = nil
    }

    private func exchange() async throws -> AccessToken {
        let issuedAt = now()
        let assertion = try JWT.assertion(for: account, now: issuedAt)

        var request = URLRequest(url: account.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion=\(assertion)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        exchangeCount += 1
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as GoogleAuthError {
            throw error
        } catch {
            throw GoogleAuthError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(fromTokenEndpoint: data, status: response.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty
        else { throw GoogleAuthError.malformedTokenResponse }

        // Google always sends expires_in; defaulting keeps a missing field from
        // producing a token that is treated as valid forever.
        let lifetime = (object["expires_in"] as? Double) ?? JWT.maximumLifetime
        return AccessToken(value: token, expiresAt: issuedAt.addingTimeInterval(lifetime))
    }

    /// The token endpoint reports failures in the body, not the status line, and
    /// the body is the only place that says *why* (§4.6).
    static func error(fromTokenEndpoint data: Data, status: Int) -> GoogleAuthError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["error"] as? String
        let detail = object?["error_description"] as? String

        if status == 403 { return .forbidden }
        guard let code else {
            return .rejected(reason: detail ?? "HTTP \(status)")
        }
        return .rejected(reason: detail.map { "\(code) — \($0)" } ?? code)
    }
}
