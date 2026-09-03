import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// #18 — trigger policy, throttling, coalescing, the offline queue and the
/// background budget.
final class SyncActorTests: XCTestCase {

    /// A movable clock, so a ten-minute throttle is testable in milliseconds.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeActor(
        _ stub: SheetStub,
        clock: Clock,
        container: ModelContainer
    ) throws -> SyncActor {
        let client = try SheetSyncHarness.makeClient(stub)
        return SyncActor(
            container: container,
            makeClient: { client },
            now: { clock.now }
        )
    }

    private func makeStub(rows: [[String]] = []) -> SheetStub {
        SheetStub(rows: ["Verbs": [SheetSyncHarness.header] + rows])
    }

    // MARK: - §4.2 trigger 1: throttled to once per 10 minutes

    func testForegroundingRepeatedlyRunsAtMostOneSyncPerTenMinutes() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        let container = try ModelStore.container(inMemory: true)
        let actor = try makeActor(stub, clock: clock, container: container)

        // Twenty foreground/background flips over nine minutes.
        for _ in 0..<20 {
            await actor.sync(.appActive)
            clock.advance(27)
        }
        XCTAssertEqual(stub.propertyRequests, 1, "the throttle should have absorbed 19 of the 20")

        // Past the window, the next foreground syncs again.
        clock.advance(10 * 60)
        await actor.sync(.appActive)
        XCTAssertEqual(stub.propertyRequests, 2)
    }

    func testPullToRefreshIgnoresTheThrottle() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        let actor = try makeActor(stub, clock: clock, container: ModelStore.container(inMemory: true))

        await actor.sync(.appActive)
        await actor.sync(.pullToRefresh)
        await actor.sync(.pullToRefresh)
        XCTAssertEqual(stub.propertyRequests, 3, "§4.2 exempts pull-to-refresh explicitly")
    }

    /// A phone that cannot reach Google must not retry on every foreground, so
    /// the throttle counts attempts rather than successes.
    func testAFailedRunStillArmsTheThrottle() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        stub.failure = SheetsError.transport("offline")
        let actor = try makeActor(stub, clock: clock, container: ModelStore.container(inMemory: true))

        let first = await actor.sync(.appActive)
        guard case .failed(_, _, let isOffline) = first.verdict, isOffline else {
            return XCTFail("expected an offline failure, got \(first.verdict)")
        }
        clock.advance(60)
        let throttled = await actor.sync(.appActive)
        XCTAssertEqual(throttled.verdict, .throttled)
    }

    // MARK: - Serialisation and coalescing

    func testTriggersArrivingMidRunCoalesceIntoOneFollowUp() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        let gate = AsyncGate()
        stub.gate = gate
        let actor = try makeActor(stub, clock: clock, container: ModelStore.container(inMemory: true))

        async let first = actor.sync(.pullToRefresh)

        // Five more triggers while the first is held open at the transport.
        let extras = (0..<5).map { _ in Task { await actor.sync(.pullToRefresh) } }
        try await Task.sleep(nanoseconds: 150_000_000)

        gate.open()
        _ = await first
        for extra in extras { _ = await extra.value }

        // One run for the first trigger, exactly one follow-up for all five —
        // not five, and not one.
        XCTAssertEqual(stub.propertyRequests, 2)
    }

    // MARK: - §4.2: each trigger asks for its own work

    func testContentEditPushesWithoutPulling() async throws {
        let clock = Clock(start)
        let noteId = UUID()
        let stub = makeStub(rows: [SheetSyncHarness.row(noteId, front: "in sheet", back: "b")])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()

        let actor = try makeActor(stub, clock: clock, container: container)
        let report = await actor.sync(.contentEdited)

        XCTAssertEqual(report.verdict, .completed)
        XCTAssertEqual(report.work, .notesOnly)
        XCTAssertEqual(report.pull, PullResult(), "a card edit must not pull the whole sheet")
    }

    func testSessionEndPushesTheLogOnly() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        context.insert(try ReviewLog(
            cardId: "c#fwd", direction: .forward, rating: 3, reviewedAt: start,
            elapsedDays: 1, scheduledDays: 3, stateBefore: .review,
            prevState: CardSchedulingSnapshot()))
        try context.save()

        let actor = try makeActor(stub, clock: clock, container: container)
        let report = await actor.sync(.sessionEnded)

        XCTAssertEqual(report.work, .logOnly)
        XCTAssertEqual(report.log.uploaded, 1)
        XCTAssertEqual(report.pull, PullResult())
        XCTAssertEqual(report.push, PushResult())
    }

    // MARK: - §4.5: offline queues, reconnect drains

    func testAirplaneModeQueuesEverythingAndReconnectDrainsItInOneRun() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        stub.reservedTabs = ["_log"]
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)

        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        // A day away from signal: five new cards typed in, and a hundred reviews.
        for index in 0..<5 {
            let note = Note(deck: deck, front: "f\(index)", back: "b\(index)")
            note.pendingUpload = true
            context.insert(note)
        }
        for index in 0..<100 {
            context.insert(try ReviewLog(
                cardId: "c\(index)#fwd", direction: .forward, rating: 3,
                reviewedAt: start.addingTimeInterval(Double(index)),
                elapsedDays: 1, scheduledDays: 3, stateBefore: .review,
                prevState: CardSchedulingSnapshot()))
        }
        try context.save()

        let actor = try makeActor(stub, clock: clock, container: container)

        stub.failure = SheetsError.transport("offline")
        let offline = await actor.sync(.appActive)
        guard case .failed(_, _, let isOffline) = offline.verdict else {
            return XCTFail("expected a failure, got \(offline.verdict)")
        }
        XCTAssertTrue(isOffline)

        // Nothing was lost: the store *is* the queue.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).filter(\.pendingUpload).count, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewLog>()).filter { !$0.uploaded }.count, 100)

        stub.failure = nil
        let drained = await actor.sync(.reconnected)

        XCTAssertEqual(drained.verdict, .completed)
        XCTAssertEqual(drained.push.appended, 5)
        XCTAssertEqual(drained.log.uploaded, 100)
        XCTAssertEqual(stub.propertyRequests, 1,
                       "the offline run never reached Google; the reconnect drained everything in one pass")

        let context2 = ModelContext(container)
        XCTAssertTrue(try context2.fetch(FetchDescriptor<Note>()).allSatisfy { !$0.pendingUpload })
        XCTAssertTrue(try context2.fetch(FetchDescriptor<ReviewLog>()).allSatisfy(\.uploaded))
    }

    // MARK: - The background task's budget

    func testCancellingARunStopsItAndLeavesTheWorkQueued() async throws {
        let clock = Clock(start)
        let stub = makeStub()
        let gate = AsyncGate()
        stub.gate = gate
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        let note = Note(deck: deck, front: "f", back: "b")
        note.pendingUpload = true
        context.insert(note)
        try context.save()

        let actor = try makeActor(stub, clock: clock, container: container)
        async let report = actor.sync(.backgroundRefresh)

        try await Task.sleep(nanoseconds: 100_000_000)
        await actor.cancelCurrentRun()
        gate.open()

        let finished = await report
        XCTAssertEqual(finished.verdict, .failed(message: "Синхронізацію перервано.",
                                                 needsSettingsAttention: false, isOffline: false))
        XCTAssertTrue(stub.appends.isEmpty, "the push should never have started")

        let after = ModelContext(container)
        XCTAssertEqual(try after.fetch(FetchDescriptor<Note>()).filter(\.pendingUpload).count, 1)
    }

    // MARK: - Not configured

    func testNoCredentialIsNotAnError() async throws {
        let clock = Clock(start)
        let actor = SyncActor(
            container: try ModelStore.container(inMemory: true),
            makeClient: { throw SheetsSettings.ConfigurationError.noKey },
            now: { clock.now }
        )
        let report = await actor.sync(.appActive)
        XCTAssertEqual(report.verdict, .notConfigured)
    }
}
