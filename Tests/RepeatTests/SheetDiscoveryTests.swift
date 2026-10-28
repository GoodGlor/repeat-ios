import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// Drives a real `SheetsClient` over a scripted transport, so discovery is
/// exercised through the actual request and parsing path rather than a mock of
/// it.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(status: Int, body: Data)]
    private(set) var paths: [String] = []

    init(_ responses: [[String: Any]]) {
        self.responses = responses.map { (200, try! JSONSerialization.data(withJSONObject: $0)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        paths.append(request.url?.path ?? "")
        // Token exchanges are interleaved with API calls; answer them separately
        // so the scripted responses line up with the calls under test.
        if request.url?.host == "oauth2.googleapis.com" {
            let body = try JSONSerialization.data(
                withJSONObject: ["access_token": "t", "expires_in": 3600.0])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
        }
        guard !responses.isEmpty else { throw SheetsError.transport("no scripted response") }
        let next = responses.removeFirst()
        return (next.body, HTTPURLResponse(url: request.url!, statusCode: next.status,
                                           httpVersion: nil, headerFields: nil)!)
    }
}

final class SheetDiscoveryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDiscovery(_ responses: [[String: Any]]) throws -> (SheetDiscovery, ModelContext) {
        let account = try ServiceAccount.parse(json: try sampleAccountJSON())
        let client = SheetsClient(
            spreadsheetId: "sheet-id",
            tokens: GoogleTokenProvider(account: account, transport: ScriptedTransport([])),
            transport: ScriptedTransport(responses)
        )
        return (SheetDiscovery(client: client), ModelContext(try ModelStore.container(inMemory: true)))
    }

    private func sampleAccountJSON() throws -> String {
        let object: [String: Any] = [
            "type": "service_account", "project_id": "p",
            "private_key": try RepeatTestKeys.makePEM(),
            "client_email": "a@b.iam.gserviceaccount.com",
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func properties(_ tabs: [(String, Int)]) -> [String: Any] {
        ["sheets": tabs.enumerated().map { index, tab in
            ["properties": ["sheetId": tab.1, "title": tab.0, "index": index]]
        }]
    }

    private func ranges(_ entries: [(String, [[String]])]) -> [String: Any] {
        ["valueRanges": entries.map { ["range": "\($0.0)!1:1", "values": $0.1] }]
    }

    func testDeckHeadersAreReadAndDecksCreated() async throws {
        let (discovery, ctx) = try makeDiscovery([
            properties([("Verbs", 0), ("_log", 1)]),
            ranges([("Verbs", [["id", "front", "back", "example", "вимова"]])]),
        ])
        let result = try await discovery.run(in: ctx, now: now)

        XCTAssertEqual(Array(result.readable.keys), ["Verbs"])
        XCTAssertEqual(result.readable["Verbs"]?.extraColumns, ["вимова"], "D1 extras discovered")
        XCTAssertEqual(result.reconciliation.created, ["Verbs"])
        XCTAssertTrue(result.malformed.isEmpty)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).map(\.sheetTitle), ["Verbs"])
    }

    /// The acceptance line: a broken deck is skipped and reported while the rest
    /// carry on. Failing the whole sync would mean one stray edit stops every
    /// deck from updating.
    func testAMalformedDeckIsSkippedAndReportedWhileOthersStillSync() async throws {
        let (discovery, ctx) = try makeDiscovery([
            properties([("Verbs", 0), ("Broken", 1), ("Nouns", 2)]),
            ranges([
                ("Verbs", [["id", "front", "back"]]),
                ("Broken", [["id", "front", "tags"]]),
                ("Nouns", [["id", "front", "back"]]),
            ]),
        ])
        let result = try await discovery.run(in: ctx, now: now)

        XCTAssertEqual(Set(result.readable.keys), ["Verbs", "Nouns"])
        XCTAssertEqual(result.malformed.count, 1)
        let reason = try XCTUnwrap(result.malformed["Broken"])
        XCTAssertTrue(reason.contains("back"), "the reason names the missing column: \(reason)")

        // Recorded on the deck so Home can show it without re-running discovery.
        let decks = try ctx.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.first { $0.sheetTitle == "Broken" }?.malformedReason, reason)
        XCTAssertNil(decks.first { $0.sheetTitle == "Verbs" }?.malformedReason)
    }

    func testAFixedHeaderClearsThePreviousReason() async throws {
        let (broken, ctx) = try makeDiscovery([
            properties([("Verbs", 0)]),
            ranges([("Verbs", [["front", "tags"]])]),
        ])
        _ = try await broken.run(in: ctx, now: now)
        XCTAssertNotNil(try ctx.fetch(FetchDescriptor<Deck>()).first?.malformedReason)

        let (fixed, _) = try makeDiscovery([
            properties([("Verbs", 0)]),
            ranges([("Verbs", [["front", "back"]])]),
        ])
        _ = try await fixed.run(in: ctx, now: now)
        XCTAssertNil(try ctx.fetch(FetchDescriptor<Deck>()).first?.malformedReason)
    }

    func testMetaIsReadAndReachesTheSchedulerConfiguration() async throws {
        let weights = "[" + SchedulerConfig().weights.map { String($0) }.joined(separator: ",") + "]"
        let (discovery, ctx) = try makeDiscovery([
            properties([("Verbs", 0), ("_meta", 9)]),
            ["valueRanges": [
                ["range": "Verbs!1:1", "values": [["front", "back"]]],
                ["range": "_meta!A:B", "values": [
                    ["schema_version", "1"],
                    ["desired_retention", "0.85"],
                    ["fsrs_params", weights],
                ]],
            ]],
        ])
        let result = try await discovery.run(in: ctx, now: now)

        XCTAssertEqual(result.schedulerConfig.desiredRetention, 0.85)
        XCTAssertEqual(result.schedulerConfig.weights.count, 21)
        XCTAssertEqual(Scheduler(config: result.schedulerConfig).algorithmVersion, .v6)
        XCTAssertTrue(result.metaProblems.isEmpty)
    }

    /// `_meta` is advisory: a bad value must not stop the sync, but applying it
    /// silently would change every future interval without anyone knowing.
    func testABadMetaValueIsReportedAndTheDefaultsStand() async throws {
        let (discovery, ctx) = try makeDiscovery([
            properties([("Verbs", 0), ("_meta", 9)]),
            ["valueRanges": [
                ["range": "Verbs!1:1", "values": [["front", "back"]]],
                ["range": "_meta!A:B", "values": [
                    ["fsrs_params", "[0.1, 0.2]"],
                    ["desired_retention", "2.0"],
                ]],
            ]],
        ])
        let result = try await discovery.run(in: ctx, now: now)

        XCTAssertEqual(result.metaProblems.count, 2)
        XCTAssertTrue(result.metaProblems.contains { $0.contains("fsrs_params") })
        XCTAssertTrue(result.metaProblems.contains { $0.contains("desired_retention") })
        // They travel with the overrides, which is what the sync actor persists —
        // a problem that only lived in this result was reported to no one.
        XCTAssertEqual(result.metaOverrides.problems, result.metaProblems)
        XCTAssertEqual(result.schedulerConfig.weights, SchedulerConfig().weights, "defaults stand")
        XCTAssertEqual(result.schedulerConfig.desiredRetention, 0.90)
        XCTAssertEqual(Array(result.readable.keys), ["Verbs"], "the decks still synced")
    }

    func testAMissingMetaTabIsNotAProblem() async throws {
        let (discovery, ctx) = try makeDiscovery([
            properties([("Verbs", 0)]),
            ranges([("Verbs", [["front", "back"]])]),
        ])
        let result = try await discovery.run(in: ctx, now: now)
        XCTAssertTrue(result.metaProblems.isEmpty)
        XCTAssertEqual(result.schedulerConfig.desiredRetention, 0.90)
    }

    /// A1 notation needs quoting for titles with spaces, and doubles apostrophes.
    func testTitlesNeedingA1QuotingRoundTrip() async throws {
        let (discovery, ctx) = try makeDiscovery([
            properties([("Phrasal verbs", 0)]),
            ["valueRanges": [["range": "'Phrasal verbs'!1:1", "values": [["front", "back"]]]]],
        ])
        let result = try await discovery.run(in: ctx, now: now)
        XCTAssertEqual(Array(result.readable.keys), ["Phrasal verbs"])
    }

    /// Only row 1 is fetched: pulling every row here would double the data
    /// transferred for a 5 000-row sheet.
    func testOnlyTheHeaderRowIsRequested() async throws {
        let transport = ScriptedTransport([
            properties([("Verbs", 0)]),
            ranges([("Verbs", [["front", "back"]])]),
        ])
        let account = try ServiceAccount.parse(json: try sampleAccountJSON())
        let client = SheetsClient(
            spreadsheetId: "sheet-id",
            tokens: GoogleTokenProvider(account: account, transport: ScriptedTransport([])),
            transport: transport
        )
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        _ = try await SheetDiscovery(client: client).run(in: ctx, now: now)

        XCTAssertEqual(transport.paths.filter { $0.contains("batchGet") }.count, 1,
                       "headers for every deck plus _meta in one request")
    }
}
