import XCTest
@testable import GoogleSheets

/// Card #12 acceptance.
final class SheetsClientTests: XCTestCase {

    /// Records what it was asked to wait for instead of waiting. The real
    /// schedule is fifteen minutes long; sleeping it would make this suite
    /// unrunnable and so untested.
    private final class RecordingSleeper: Sleeper, @unchecked Sendable {
        private let lock = NSLock()
        private var _slept: [TimeInterval] = []
        var slept: [TimeInterval] { lock.withLock { _slept } }
        func sleep(for duration: TimeInterval) async throws {
            try Task.checkCancellation()
            lock.withLock { _slept.append(duration) }
        }
    }

    private func makeClient(
        _ stub: StubTransport,
        sleeper: Sleeper = RecordingSleeper(),
        policy: RetryPolicy = RetryPolicy()
    ) throws -> SheetsClient {
        let account = try ServiceAccount.parse(json: try TestKeys.serviceAccountJSON())
        let tokenStub = StubTransport.alwaysReturningToken()
        return SheetsClient(
            spreadsheetId: "sheet-id",
            tokens: GoogleTokenProvider(account: account, transport: tokenStub),
            transport: stub,
            policy: policy,
            sleeper: sleeper
        )
    }

    // MARK: - Requests

    func testSheetPropertiesRequestsOnlyWhatItNeeds() async throws {
        let stub = StubTransport(responses: [.json(["sheets": [
            ["properties": ["sheetId": 0, "title": "Verbs", "index": 0]],
            ["properties": ["sheetId": 12, "title": "_log", "index": 1]],
        ]])])
        let sheets = try await makeClient(stub).sheetProperties()

        XCTAssertEqual(sheets.map(\.title), ["Verbs", "_log"])
        XCTAssertEqual(sheets.map(\.sheetId), [0, 12])
        XCTAssertFalse(sheets[0].isReserved)
        XCTAssertTrue(sheets[1].isReserved, "tabs prefixed with _ are reserved (§3.1)")

        let request = try XCTUnwrap(stub.requests.first)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, SheetsClient.host)
        XCTAssertEqual(components.path, "/v4/spreadsheets/sheet-id")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "fields" })?.value,
                       "sheets.properties")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.test-token")
    }

    /// §4.3 step 2 fetches every deck tab in one request; issuing one per deck
    /// would multiply quota use by the deck count.
    func testBatchGetSendsEveryRangeInASingleRequest() async throws {
        let stub = StubTransport(responses: [.json(["valueRanges": [
            ["range": "Verbs!A1:Z", "values": [["id", "front"], ["1", "a"]]],
            ["range": "'Phrasal verbs'!A1:Z", "values": [["id"]]],
        ]])])
        let client = try makeClient(stub)
        let ranges = try await client.batchGet(ranges: ["Verbs!A1:Z", "'Phrasal verbs'!A1:Z"])

        XCTAssertEqual(stub.requestCount, 1)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].sheetTitle, "Verbs")
        XCTAssertEqual(ranges[1].sheetTitle, "Phrasal verbs", "quoted titles are unquoted")

        let components = try XCTUnwrap(URLComponents(url: stub.requests[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.filter { $0.name == "ranges" }.count, 2)
    }

    func testAnEmptyRangeListMakesNoRequestAtAll() async throws {
        let stub = StubTransport(responses: [])
        let ranges = try await makeClient(stub).batchGet(ranges: [])
        XCTAssertTrue(ranges.isEmpty)
        XCTAssertEqual(stub.requestCount, 0)
    }

    /// Google returns numbers and booleans unquoted and drops trailing empty
    /// cells, so rows arrive ragged and mixed-typed.
    func testValuesAreNormalisedToStringsWithBooleansPreserved() async throws {
        let stub = StubTransport(responses: [.json(["valueRanges": [[
            "range": "Verbs!A1:Z",
            "values": [["id", "front", "reverse"], ["1", 42, true], ["2", 3.5, false], ["3"]],
        ]]])])
        let ranges = try await makeClient(stub).batchGet(ranges: ["Verbs!A1:Z"])
        let values = ranges[0].values

        XCTAssertEqual(values[1], ["1", "42", "TRUE"], "TRUE must not arrive as 1")
        XCTAssertEqual(values[2], ["2", "3.5", "FALSE"])
        XCTAssertEqual(values[3], ["3"], "ragged rows stay ragged rather than being padded wrongly")
    }

    func testBatchUpdateUsesRawForIdWriteBackAndUserEnteredForContent() async throws {
        let stub = StubTransport(responses: [.json([:]), .json([:])])
        let client = try makeClient(stub)
        let update = ValueRange(range: "Verbs!A2", values: [["uuid"]])

        try await client.batchUpdate([update], raw: true)
        try await client.batchUpdate([update], raw: false)

        func option(_ index: Int) throws -> String {
            let body = try XCTUnwrap(stub.requests[index].httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(object["valueInputOption"] as? String)
        }
        XCTAssertEqual(try option(0), "RAW", "§4.3 step 5 writes ids back raw")
        XCTAssertEqual(try option(1), "USER_ENTERED")
    }

    func testAppendInsertsRowsRatherThanOverwriting() async throws {
        let stub = StubTransport(responses: [.json([:])])
        try await makeClient(stub).append(range: "Verbs!A:H", values: [["a", "b"]])

        let request = try XCTUnwrap(stub.requests.first)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.path.hasSuffix(":append"))
        // Asserted on the *encoded* path. Reading `components.path` decodes it,
        // which is why the original double-encoding bug passed this test while
        // Google rejected the request.
        XCTAssertEqual(components.percentEncodedPath,
                       "/v4/spreadsheets/sheet-id/values/Verbs!A%3AH:append")
        XCTAssertEqual(components.queryItems?.first { $0.name == "insertDataOption" }?.value, "INSERT_ROWS")
        XCTAssertEqual(components.queryItems?.first { $0.name == "valueInputOption" }?.value, "USER_ENTERED")
    }

    func testAppendingNothingMakesNoRequest() async throws {
        let stub = StubTransport(responses: [])
        try await makeClient(stub).append(range: "Verbs!A:H", values: [])
        XCTAssertEqual(stub.requestCount, 0)
    }

    /// §8 restricts network access to googleapis.com.
    func testEveryRequestGoesToTheSheetsHost() async throws {
        let stub = StubTransport(responses: [
            .json(["sheets": []]), .json(["valueRanges": []]), .json([:]), .json([:]),
        ])
        let client = try makeClient(stub)
        _ = try await client.sheetProperties()
        _ = try await client.batchGet(ranges: ["Verbs!A1:Z"])
        try await client.batchUpdate([ValueRange(range: "A1", values: [["x"]])], raw: true)
        try await client.append(range: "Verbs!A:H", values: [["x"]])

        XCTAssertEqual(stub.requestCount, 4)
        for request in stub.requests {
            XCTAssertEqual(request.url?.host, "sheets.googleapis.com")
            XCTAssertEqual(request.url?.scheme, "https")
        }
    }

    // MARK: - Backoff (§4.6)

    func testA429RetriesOnTheDocumentedScheduleThenGivesUp() async throws {
        let stub = StubTransport(responses: [])
        stub.repeating = .json(["error": ["message": "Quota exceeded"]], status: 429)
        let sleeper = RecordingSleeper()
        let client = try makeClient(stub, sleeper: sleeper)

        do {
            _ = try await client.sheetProperties()
            XCTFail("expected to give up")
        } catch let error as SheetsError {
            XCTAssertEqual(error, .rateLimited(afterAttempts: 5))
            XCTAssertFalse(error.needsSettingsAttention, "quota is not the owner's to fix")
        }

        XCTAssertEqual(stub.requestCount, 5, "five tries, then wait for the next trigger (§4.2)")
        XCTAssertEqual(sleeper.slept, [60, 120, 240, 480], "1, 2, 4, 8 minutes")
    }

    func testServerErrorsAreRetriedAndSucceedWhenGoogleRecovers() async throws {
        let stub = StubTransport(responses: [
            .json(["error": ["message": "backend error"]], status: 503),
            .json(["error": ["message": "backend error"]], status: 500),
            .json(["sheets": [["properties": ["sheetId": 0, "title": "Verbs", "index": 0]]]]),
        ])
        let sleeper = RecordingSleeper()
        let sheets = try await makeClient(stub, sleeper: sleeper).sheetProperties()

        XCTAssertEqual(sheets.map(\.title), ["Verbs"])
        XCTAssertEqual(stub.requestCount, 3)
        XCTAssertEqual(sleeper.slept, [60, 120])
    }

    /// Retrying a wrong id or an unshared sheet wastes the window and hides the
    /// real problem behind minutes of silence.
    func testPermanentFailuresAreNotRetried() async throws {
        for (status, expected) in [(404, SheetsError.spreadsheetNotFound), (403, .notShared)] {
            let stub = StubTransport(responses: [])
            stub.repeating = .json(["error": ["message": "nope"]], status: status)
            let sleeper = RecordingSleeper()
            do {
                _ = try await makeClient(stub, sleeper: sleeper).sheetProperties()
                XCTFail("expected failure for \(status)")
            } catch let error as SheetsError {
                XCTAssertEqual(error, expected)
                XCTAssertTrue(error.needsSettingsAttention, "\(status) is the owner's to fix")
            }
            XCTAssertEqual(stub.requestCount, 1, "\(status) must not be retried")
            XCTAssertTrue(sleeper.slept.isEmpty)
        }
    }

    /// A 401 mid-session means the cached token died. One silent refresh is
    /// right; a second means the credential is bad and the owner must act.
    func testA401RefreshesTheTokenOnceAndThenSurfaces() async throws {
        let stub = StubTransport(responses: [
            .json(["error": ["message": "expired"]], status: 401),
            .json(["sheets": [["properties": ["sheetId": 0, "title": "Verbs", "index": 0]]]]),
        ])
        let sheets = try await makeClient(stub).sheetProperties()
        XCTAssertEqual(sheets.map(\.title), ["Verbs"])
        XCTAssertEqual(stub.requestCount, 2)

        let persistent = StubTransport(responses: [])
        persistent.repeating = .json(["error": ["message": "revoked"]], status: 401)
        do {
            _ = try await makeClient(persistent).sheetProperties()
            XCTFail("expected the second 401 to surface")
        } catch let error as SheetsError {
            XCTAssertTrue(error.needsSettingsAttention)
        }
        XCTAssertEqual(persistent.requestCount, 2, "one refresh, not an endless loop")
    }

    // MARK: - Cancellation

    /// A sync cancelled mid-backoff must stop, not wake up minutes later and fire.
    func testARequestIsCancellableWhileWaitingToRetry() async throws {
        let stub = StubTransport(responses: [])
        stub.repeating = .json(["error": ["message": "quota"]], status: 429)

        /// Blocks until cancelled, standing in for a real minutes-long wait.
        struct BlockingSleeper: Sleeper {
            func sleep(for duration: TimeInterval) async throws {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let client = try makeClient(stub, sleeper: BlockingSleeper())

        let task = Task { try await client.sheetProperties() }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThanOrEqual(stub.requestCount, 2, "it stopped rather than working through the schedule")
    }

    // MARK: - Parsing at scale

    /// The 5k-row budget in §8 cannot be measured without a live account, but
    /// parsing is the part this package controls, so it is measured here.
    func testFiveThousandRowsParseWellInsideTheBudget() async throws {
        let rows: [[Any]] = (0..<5000).map { index in
            ["id-\(index)", "front \(index)", "back \(index)", "example", "tag", index.isMultiple(of: 2)]
        }
        let stub = StubTransport(responses: [.json(["valueRanges": [
            ["range": "Verbs!A1:Z", "values": rows],
        ]])])
        let client = try makeClient(stub)

        let started = Date()
        let ranges = try await client.batchGet(ranges: ["Verbs!A1:Z"])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(ranges[0].values.count, 5000)
        XCTAssertEqual(ranges[0].values[1][5], "FALSE")
        XCTAssertLessThan(elapsed, 2.0, "parsing must leave the network the bulk of §8's 10s budget")
    }

    // MARK: - Malformed responses

    func testAResponseWithoutTheExpectedShapeIsReportedAsMalformed() async throws {
        for stub in [
            StubTransport(responses: [.init(status: 200, body: Data("<html>".utf8))]),
            StubTransport(responses: [.json(["unexpected": true])]),
        ] {
            do {
                _ = try await makeClient(stub).sheetProperties()
                XCTFail("expected malformed")
            } catch let error as SheetsError {
                guard case .malformedResponse = error else { return XCTFail("got \(error)") }
                XCTAssertFalse(error.needsSettingsAttention)
            }
        }
    }
}
