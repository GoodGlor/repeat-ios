import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// #17 — the append-only `_log` push.
final class LogPushTests: XCTestCase {
    // MARK: - Fixtures

    private func makeLog(
        in context: ModelContext,
        cardId: String = "c#fwd",
        rating: Int = 3,
        at reviewedAt: Date,
        state: SchedulingState = .review,
        uploaded: Bool = false
    ) throws {
        let log = try ReviewLog(
            cardId: cardId,
            direction: .forward,
            rating: rating,
            reviewedAt: reviewedAt,
            elapsedDays: 4,
            scheduledDays: 11,
            stateBefore: state,
            prevState: CardSchedulingSnapshot(),
            uploaded: uploaded
        )
        context.insert(log)
    }

    private func discovery(hasLog: Bool = true) -> DiscoveryResult {
        var result = DiscoveryResult()
        result.hasLogSheet = hasLog
        return result
    }

    // MARK: - Acceptance: 1200 rows in three requests, no duplicates, no gaps

    func testBacklogUploadsInChunksOfFiveHundred() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<1200 {
            try makeLog(
                in: context,
                cardId: "card-\(index)#fwd",
                at: start.addingTimeInterval(Double(index))
            )
        }
        try context.save()

        let stub = SheetStub()
        let result = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(), in: context)

        XCTAssertEqual(result.requests, 3)
        XCTAssertEqual(result.uploaded, 1200)
        XCTAssertEqual(stub.appends.map(\.values.count), [500, 500, 200])

        // No gaps and no duplicates: every card appears exactly once, and the
        // rows arrive in review order across the chunk boundaries.
        let sent = stub.appends.flatMap(\.values)
        XCTAssertEqual(sent.count, 1200)
        XCTAssertEqual(Set(sent.map { $0[0] }).count, 1200)
        XCTAssertEqual(sent.map { $0[0] }, (0..<1200).map { "card-\($0)#fwd" })

        let remaining = try context.fetch(FetchDescriptor<ReviewLog>()).filter { !$0.uploaded }
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Acceptance: an interrupted upload queues the rest rather than losing it

    func testInterruptedUploadLeavesRemainingRowsQueued() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<1200 {
            try makeLog(
                in: context,
                cardId: "card-\(index)#fwd",
                at: start.addingTimeInterval(Double(index))
            )
        }
        try context.save()

        // Dies during the third request, after two chunks are safely on Google's
        // side — the shape of a phone losing signal mid-sync.
        let stub = SheetStub()
        stub.failAppendsAfter = 2
        let push = LogPush(client: try SheetSyncHarness.makeClient(stub))

        do {
            _ = try await push.run(discovery: discovery(), in: context)
            XCTFail("the failing append should have propagated")
        } catch {}

        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.filter(\.uploaded).count, 1000)
        XCTAssertEqual(logs.filter { !$0.uploaded }.count, 200)

        // The next trigger sends exactly the 200 that never landed — no gap, and
        // no re-send of the 1000 that did.
        stub.failAppendsAfter = nil
        let resumed = try await push.run(discovery: discovery(), in: context)
        XCTAssertEqual(resumed.uploaded, 200)
        XCTAssertEqual(resumed.requests, 1)

        let resent = stub.appends.dropFirst(2).flatMap(\.values).map { $0[0] }
        XCTAssertEqual(resent, (1000..<1200).map { "card-\($0)#fwd" })
    }

    // MARK: - Row shape

    func testRowMatchesTheSpecColumnOrder() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        try makeLog(
            in: context,
            cardId: "abc#fwd",
            rating: 1,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            state: .relearning
        )
        try context.save()

        let stub = SheetStub()
        _ = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(), in: context)

        XCTAssertEqual(stub.appends.count, 1)
        XCTAssertEqual(
            stub.appends[0].values[0],
            ["abc#fwd", "fwd", "1", "2023-11-14T22:13:20Z", "4", "11", "relearning"]
        )
    }

    func testUndoMarkerRowsAreUploadedLikeAnyOther() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        try makeLog(in: context, rating: 0, at: Date(timeIntervalSince1970: 1_700_000_000))
        try context.save()

        let stub = SheetStub()
        let result = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(), in: context)

        XCTAssertEqual(result.uploaded, 1)
        XCTAssertEqual(stub.appends[0].values[0][2], "0")
    }

    // MARK: - The `_log` tab

    func testCreatesTheLogTabWithItsHeaderWhenMissing() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        try makeLog(in: context, at: Date(timeIntervalSince1970: 1_700_000_000))
        try context.save()

        let stub = SheetStub()
        let result = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(hasLog: false), in: context)

        XCTAssertTrue(result.createdSheet)
        XCTAssertEqual(stub.addedSheets, ["_log"])
        XCTAssertEqual(stub.appends.first?.values, [LogPush.header])
        XCTAssertEqual(stub.appends.count, 2)
    }

    func testDoesNotTouchTheSheetWhenNothingIsPending() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        try makeLog(in: context, at: Date(timeIntervalSince1970: 1_700_000_000), uploaded: true)
        try context.save()

        let stub = SheetStub()
        let result = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(hasLog: false), in: context)

        XCTAssertEqual(result, LogPushResult())
        XCTAssertTrue(stub.appends.isEmpty)
        XCTAssertTrue(stub.addedSheets.isEmpty)
    }

    /// The append must address `_log!A:G`, not `A:ZZ` — an unbounded range lets a
    /// stray cell to the right define the table and push new rows below it.
    func testAppendsToTheBoundedLogRange() async throws {
        let (context, _) = try SheetSyncHarness.makeContext()
        try makeLog(in: context, at: Date(timeIntervalSince1970: 1_700_000_000))
        try context.save()

        let stub = SheetStub()
        _ = try await LogPush(client: try SheetSyncHarness.makeClient(stub))
            .run(discovery: discovery(), in: context)

        XCTAssertTrue(
            stub.appends[0].range.hasSuffix("/values/_log!A%3AG:append"),
            "unexpected append path: \(stub.appends[0].range)"
        )
    }
}
