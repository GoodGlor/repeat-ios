import XCTest
@testable import GoogleSheets

/// Card #11, exchange and caching half.
final class TokenProviderTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func account() throws -> ServiceAccount {
        try ServiceAccount.parse(json: try TestKeys.serviceAccountJSON())
    }

    /// A settable clock, so token expiry can be tested without waiting an hour.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
    }

    // MARK: - The exchange request

    func testTheTokenRequestIsTheJWTBearerGrantGoogleExpects() async throws {
        let stub = StubTransport.oneToken()
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        let token = try await provider.token()
        XCTAssertEqual(token, "ya29.test-token")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let fields = stub.formFields(of: request)
        XCTAssertEqual(fields["grant_type"], "urn:ietf:params:oauth:grant-type:jwt-bearer")
        let assertion = try XCTUnwrap(fields["assertion"])
        XCTAssertEqual(assertion.split(separator: ".").count, 3)
    }

    /// §8 limits network access to googleapis.com; the audience and the URL both
    /// come from the credential, so a tampered key must not redirect the exchange.
    func testTheExchangeOnlyEverTalksToTheCredentialsTokenEndpoint() async throws {
        let stub = StubTransport.oneToken()
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })
        _ = try await provider.token()
        for request in stub.requests {
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
        }
    }

    // MARK: - Caching (§4.1)

    func testTheTokenIsReusedAcrossCallsRatherThanRefetched() async throws {
        let stub = StubTransport.alwaysReturningToken()
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        for _ in 0..<5 { _ = try await provider.token() }
        XCTAssertEqual(stub.requestCount, 1, "one exchange, not five")
        let count = await provider.exchangeCount
        XCTAssertEqual(count, 1)
    }

    func testTheTokenIsRefreshedFiveMinutesBeforeExpiryNotAtExpiry() async throws {
        let clock = Clock(start)
        let stub = StubTransport.alwaysReturningToken(expiresIn: 3600)
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { clock.now })

        _ = try await provider.token()
        XCTAssertEqual(stub.requestCount, 1)

        // 54 minutes in: still more than 5 minutes of life left.
        clock.advance(54 * 60)
        _ = try await provider.token()
        XCTAssertEqual(stub.requestCount, 1, "still usable")

        // 56 minutes in: inside the 5-minute margin, so it must be replaced before
        // it can expire between being handed out and being used.
        clock.advance(2 * 60)
        _ = try await provider.token()
        XCTAssertEqual(stub.requestCount, 2)
    }

    /// A sync run fires several requests at once. Without sharing the in-flight
    /// exchange, each would mint its own assertion and burn a round trip.
    func testConcurrentCallersShareASingleExchange() async throws {
        let stub = StubTransport.alwaysReturningToken()
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.token() } }
            var seen: Set<String> = []
            for try await token in group { seen.insert(token) }
            XCTAssertEqual(seen, ["ya29.test-token"])
        }
        XCTAssertEqual(stub.requestCount, 1, "eight callers, one round trip")
    }

    func testInvalidateForcesTheNextCallToMintAFreshToken() async throws {
        let stub = StubTransport.alwaysReturningToken()
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        _ = try await provider.token()
        await provider.invalidate()
        _ = try await provider.token()
        XCTAssertEqual(stub.requestCount, 2, "a 401 must be able to force a refresh")
    }

    func testAMissingExpiresInDoesNotProduceATokenThatNeverExpires() async throws {
        let clock = Clock(start)
        let stub = StubTransport(responses: [
            .json(["access_token": "a"]),
            .json(["access_token": "b", "expires_in": 3600.0]),
        ])
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { clock.now })

        let first = try await provider.token()
        XCTAssertEqual(first, "a")
        clock.advance(JWT.maximumLifetime)
        let second = try await provider.token()
        XCTAssertEqual(second, "b", "the default lifetime still expires")
    }

    // MARK: - Failures name their cause (§4.6)

    func testARevokedKeyIsReportedWithGooglesOwnReason() async throws {
        let stub = StubTransport(responses: [.json([
            "error": "invalid_grant",
            "error_description": "Invalid JWT Signature.",
        ], status: 400)])
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        do {
            _ = try await provider.token()
            XCTFail("expected a rejection")
        } catch let error as GoogleAuthError {
            XCTAssertEqual(error, .rejected(reason: "invalid_grant — Invalid JWT Signature."))
            XCTAssertTrue(error.needsSettingsAttention, "§4.6 banner links to Settings")
            XCTAssertTrue(error.description.contains("Invalid JWT Signature."))
        }
    }

    func testAForbiddenResponseIsDistinguishedFromABadKey() async throws {
        let stub = StubTransport(responses: [.json(["error": "forbidden"], status: 403)])
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })
        do {
            _ = try await provider.token()
            XCTFail("expected forbidden")
        } catch let error as GoogleAuthError {
            XCTAssertEqual(error, .forbidden)
            XCTAssertTrue(error.description.contains("Поділіться таблицею"))
        }
    }

    /// A network blip must not send the owner to Settings to re-paste a key that
    /// is perfectly fine.
    func testATransportFailureDoesNotAskTheOwnerToFixTheirKey() async throws {
        let stub = StubTransport(error: URLError(.notConnectedToInternet))
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })
        do {
            _ = try await provider.token()
            XCTFail("expected a transport failure")
        } catch let error as GoogleAuthError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
            XCTAssertFalse(error.needsSettingsAttention)
        }
    }

    func testAnUnparseableSuccessResponseIsReportedAsMalformed() async throws {
        let stub = StubTransport(responses: [.init(status: 200, body: Data("<html>".utf8))])
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })
        do {
            _ = try await provider.token()
            XCTFail("expected malformed")
        } catch let error as GoogleAuthError {
            XCTAssertEqual(error, .malformedTokenResponse)
            XCTAssertFalse(error.needsSettingsAttention)
        }
    }

    func testAFailedExchangeIsNotCachedAsSuccess() async throws {
        let stub = StubTransport(responses: [
            .json(["error": "invalid_grant"], status: 400),
            .json(["access_token": "recovered", "expires_in": 3600.0]),
        ])
        let provider = GoogleTokenProvider(account: try account(), transport: stub, now: { self.start })

        _ = try? await provider.token()
        let recovered = try await provider.token()
        XCTAssertEqual(recovered, "recovered", "a failure must not poison the cache")
    }
}
