import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// #18 — the main-actor façade: debouncing, the status line's wording, and the
/// promise that a trigger never blocks the caller.
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCoordinator(
        _ stub: SheetStub,
        container: ModelContainer,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) throws -> SyncCoordinator {
        let client = try SheetSyncHarness.makeClient(stub)
        let now = start
        return SyncCoordinator(
            actor: SyncActor(container: container, makeClient: { client }, now: { now }),
            sleep: sleep
        )
    }

    private func makeStub() -> SheetStub {
        SheetStub(rows: ["Verbs": [SheetSyncHarness.header]])
    }

    /// §4.2 trigger 3: a burst of keystrokes is one sync, not twenty.
    func testEditsWithinTheDebounceWindowCollapseIntoOneSync() async throws {
        let stub = makeStub()
        let released = AsyncGate()
        let coordinator = try makeCoordinator(
            stub,
            container: ModelStore.container(inMemory: true),
            // Stands in for the 3 s wait: the test decides when it elapses.
            sleep: { _ in await released.wait() }
        )

        for _ in 0..<20 { coordinator.trigger(.contentEdited) }
        XCTAssertEqual(stub.propertyRequests, 0, "nothing may fire during the window")

        released.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stub.propertyRequests, 1, "each edit replaces the pending sync")
    }

    /// "Sync never blocks the UI" (§4.2) — `trigger` returns before the work
    /// starts, which is what lets it be called from a view's body.
    func testTriggerReturnsWithoutWaitingForTheSync() async throws {
        let stub = makeStub()
        let gate = AsyncGate()
        stub.gate = gate
        let coordinator = try makeCoordinator(stub, container: ModelStore.container(inMemory: true))

        coordinator.trigger(.pullToRefresh)
        // Still held at the transport; the call above has already returned.
        XCTAssertEqual(stub.propertyRequests, 0)
        gate.open()
    }

    func testStatusDistinguishesOfflineFromSomethingWorthFixing() async throws {
        let stub = makeStub()
        let coordinator = try makeCoordinator(stub, container: ModelStore.container(inMemory: true))

        stub.failure = SheetsError.transport("no route to host")
        await coordinator.performAndWait(.pullToRefresh)
        XCTAssertEqual(coordinator.status, .offline)

        // A key the owner has to fix reads differently and links to Settings.
        // 403 as a status, not a thrown error: a throw *is* a transport failure.
        stub.failure = nil
        stub.failureStatus = 403
        await coordinator.performAndWait(.pullToRefresh)
        XCTAssertEqual(coordinator.status,
                       .failed(message: SheetsError.notShared.description, needsAttention: true))

        stub.failureStatus = nil
        await coordinator.performAndWait(.pullToRefresh)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(coordinator.lastSyncedAt, start)
    }

    func testAThrottledTriggerDoesNotClearAStandingError() async throws {
        let stub = makeStub()
        let coordinator = try makeCoordinator(stub, container: ModelStore.container(inMemory: true))

        stub.failureStatus = 403
        await coordinator.performAndWait(.appActive)
        let failed = coordinator.status
        XCTAssertEqual(failed, .failed(message: SheetsError.notShared.description,
                                       needsAttention: true))

        // A second foreground inside the window does nothing — and must therefore
        // leave the banner exactly as it was.
        await coordinator.performAndWait(.appActive)
        XCTAssertEqual(coordinator.status, failed)
    }

    func testNoCredentialShowsAsNotConfiguredRatherThanAFailure() async throws {
        let coordinator = SyncCoordinator(
            actor: SyncActor(
                container: try ModelStore.container(inMemory: true),
                makeClient: { throw SheetsSettings.ConfigurationError.noKey }
            )
        )
        await coordinator.performAndWait(.appActive)
        XCTAssertEqual(coordinator.status, .notConfigured)
    }

    func testReconnectingTriggersASync() async throws {
        final class FakeReachability: NetworkReachability, @unchecked Sendable {
            var onReconnect: (@Sendable () -> Void)?
            func start(onReconnect: @escaping @Sendable () -> Void) { self.onReconnect = onReconnect }
            func stop() { onReconnect = nil }
        }

        let stub = makeStub()
        let client = try SheetSyncHarness.makeClient(stub)
        let reachability = FakeReachability()
        let now = start
        let coordinator = SyncCoordinator(
            actor: SyncActor(container: try ModelStore.container(inMemory: true),
                             makeClient: { client }, now: { now }),
            reachability: reachability
        )
        coordinator.startMonitoring()

        reachability.onReconnect?()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stub.propertyRequests, 1)
    }

    /// The actor's context is made where the actor is made — `RepeatApp.init`, on
    /// the main thread — and used on the actor ever after. SwiftData binds a
    /// context to the queue that created it and logs the moment it is used
    /// elsewhere; on the **main** context that log line was the 2026-09-04 crash.
    /// The actor's context has to be created on the actor.
    func testTheActorsContextIsMadeOnTheActorNotOnMain() async throws {
        let stub = makeStub()
        let coordinator = try makeCoordinator(stub, container: ModelStore.container(inMemory: true))
        let start = Date()

        await coordinator.performAndWait(.pullToRefresh)

        XCTAssertEqual(stub.propertyRequests, 1, "the sync did not run")
        let uses = try OffQueue.uses(since: start)
        XCTAssertTrue(uses.isEmpty, "a context was used off the queue that made it:\n"
                      + uses.joined(separator: "\n"))
    }
}
