import XCTest
import SwiftData
import GoogleSheets
@testable import Repeat

/// #19 — the status line's wording and the conflicts list's one-tap recovery.
@MainActor
final class SyncStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The line reports the last *success*, not the last attempt

    func testTheLineReportsTheLastSuccessfulSyncNotTheLastAttempt() async throws {
        let stub = SheetStub(rows: ["Verbs": [SheetSyncHarness.header]])
        let client = try SheetSyncHarness.makeClient(stub)
        let synced = now
        let coordinator = SyncCoordinator(
            actor: SyncActor(container: try ModelStore.container(inMemory: true),
                             makeClient: { client }, now: { synced })
        )

        await coordinator.performAndWait(.pullToRefresh)
        XCTAssertEqual(coordinator.lastSyncedAt, synced)

        // An hour later the phone loses signal and tries again.
        stub.failure = SheetsError.transport("offline")
        await coordinator.performAndWait(.pullToRefresh)

        XCTAssertEqual(coordinator.lastSyncedAt, synced, "a failed attempt must not move the clock")
        let line = SyncStatusFormatter.line(
            status: coordinator.status,
            lastSyncedAt: coordinator.lastSyncedAt,
            now: synced.addingTimeInterval(3600)
        )
        XCTAssertEqual(line.text, "Офлайн — зміни синхронізуються пізніше")
        XCTAssertEqual(line.tone, .waiting, "offline is not the owner's problem to fix")

        // And once it is idle again, the age is measured from the success.
        let idle = SyncStatusFormatter.line(
            status: .idle, lastSyncedAt: synced, now: synced.addingTimeInterval(3600))
        XCTAssertEqual(idle.text, "Синхронізовано 1 год тому")
    }

    func testElapsedIsCoarseAndAvoidsInflectedUnits() {
        func text(_ seconds: TimeInterval) -> String {
            SyncStatusFormatter.elapsed(since: now, now: now.addingTimeInterval(seconds))
        }
        XCTAssertEqual(text(0), "щойно")
        XCTAssertEqual(text(59), "щойно")
        XCTAssertEqual(text(120), "2 хв тому")
        XCTAssertEqual(text(3600 * 5), "5 год тому")
        XCTAssertEqual(text(86_400 * 3), "3 дн тому")
        XCTAssertEqual(text(-10), "щойно", "a clock that jumped backwards must not print a negative age")
    }

    func testAnAuthFailureOffersSettingsAndAServerErrorDoesNot() {
        let auth = SyncStatusFormatter.line(
            status: .failed(message: SheetsError.notShared.description, needsAttention: true),
            lastSyncedAt: nil, now: now)
        XCTAssertTrue(auth.linksToSettings)
        XCTAssertEqual(auth.tone, .attention)
        XCTAssertEqual(auth.text, SheetsError.notShared.description)

        // Google having a bad day is not something the owner can act on, so it
        // neither shouts nor sends them to Settings.
        let server = SyncStatusFormatter.line(
            status: .failed(message: "HTTP 500", needsAttention: false), lastSyncedAt: nil, now: now)
        XCTAssertFalse(server.linksToSettings)
        XCTAssertEqual(server.text, "Не вдалося синхронізувати — спробуємо ще раз")
    }

    func testNeverSyncedReadsAsWaitingRatherThanBroken() {
        let line = SyncStatusFormatter.line(status: .idle, lastSyncedAt: nil, now: now)
        XCTAssertEqual(line.text, "Ще не синхронізовано")
        XCTAssertEqual(line.tone, .waiting)
    }

    // MARK: - A discarded edit is recoverable

    func testReapplyingAConflictRestoresTheEditAndQueuesItForPush() throws {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        let note = Note(deck: deck, front: "run", back: "версія з Таблиці")
        note.refreshContentHash()
        note.lastSyncedHash = note.contentHash
        note.pendingUpload = false
        context.insert(note)

        let conflict = SyncConflict(
            noteId: note.id, deckTitle: "Verbs", occurredAt: now,
            front: "run", back: "моя правка", example: "he runs",
            winningFront: "run", winningBack: "версія з Таблиці")
        context.insert(conflict)
        try context.save()

        let outcome = try ConflictResolver.reapply(conflict, in: context, now: now)

        XCTAssertEqual(outcome, .reapplied)
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(restored.back, "моя правка")
        XCTAssertEqual(restored.example, "he runs")
        XCTAssertTrue(restored.pendingUpload, "the normal push path carries it up")
        XCTAssertEqual(restored.contentHash, restored.contentHash)
        XCTAssertNotEqual(restored.contentHash, restored.lastSyncedHash,
                          "the two sides disagree again; saying otherwise would let the next pull discard it a second time")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncConflict>()).isEmpty)
    }

    /// The re-applied edit must actually reach the Sheet, not merely look
    /// restored on the phone.
    func testAReappliedEditIsPushedOnTheNextSync() async throws {
        let noteId = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            SheetSyncHarness.header,
            SheetSyncHarness.row(noteId, front: "run", back: "версія з Таблиці"),
        ]])
        let container = try ModelStore.container(inMemory: true)
        let context = ModelContext(container)
        let client = try SheetSyncHarness.makeClient(stub)
        let when = now

        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()

        let actor = SyncActor(container: container, makeClient: { client }, now: { when })
        await actor.sync(.pullToRefresh)

        let note = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first)
        let conflict = SyncConflict(
            noteId: note.id, deckTitle: "Verbs", occurredAt: when,
            front: "run", back: "моя правка", example: nil,
            winningFront: "run", winningBack: "версія з Таблиці")
        context.insert(conflict)
        try context.save()

        try ConflictResolver.reapply(conflict, in: context, now: when)
        let pushed = await actor.sync(.contentEdited)

        XCTAssertEqual(pushed.push.updated, 1)
        XCTAssertTrue(
            stub.writtenRows.contains { $0.contains("моя правка") },
            "the restored edit has to reach the Sheet, not just look restored on the phone"
        )
    }

    func testAConflictForADeletedNoteIsClearedRatherThanLeftForever() throws {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let conflict = SyncConflict(
            noteId: UUID(), deckTitle: "Verbs", occurredAt: now,
            front: "f", back: "b", example: nil, winningFront: "f", winningBack: "б")
        context.insert(conflict)
        try context.save()

        XCTAssertEqual(try ConflictResolver.reapply(conflict, in: context, now: now), .noteGone)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncConflict>()).isEmpty)
    }

    func testDismissingAConflictRemovesItWithoutTouchingTheNote() throws {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        let note = Note(deck: deck, front: "run", back: "версія з Таблиці")
        context.insert(note)
        let conflict = SyncConflict(
            noteId: note.id, deckTitle: "Verbs", occurredAt: now,
            front: "run", back: "моя правка", example: nil,
            winningFront: "run", winningBack: "версія з Таблиці")
        context.insert(conflict)
        try context.save()

        try ConflictResolver.dismiss(conflict, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncConflict>()).isEmpty)
        XCTAssertEqual(try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first).back,
                       "версія з Таблиці")
        XCTAssertFalse(try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first).pendingUpload)
    }

    // MARK: - §6.2: the section is hidden when empty

    func testNeedsAttentionIsEmptyWhenThereIsNothingToSay() {
        XCTAssertTrue(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .idle))
        XCTAssertTrue(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .syncing))
    }

    /// Offline is not the owner's problem, and neither is Google having a bad
    /// day. A permanent red row for anyone who commutes underground would train
    /// them to ignore the section that matters.
    func testOfflineAndTransientFailuresDoNotDemandAttention() {
        XCTAssertTrue(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .offline))
        XCTAssertTrue(NeedsAttention.isEmpty(
            conflicts: 0, malformedDecks: 0,
            status: .failed(message: "HTTP 500", needsAttention: false)))
        XCTAssertNil(NeedsAttention.authProblem(status: .offline))
    }

    func testEachCauseOpensTheSection() {
        XCTAssertFalse(NeedsAttention.isEmpty(conflicts: 1, malformedDecks: 0, status: .idle))
        XCTAssertFalse(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 1, status: .idle))
        XCTAssertFalse(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .notConfigured))
        // §5.1: a `_meta` value the app refused is a fourth cause. It was being
        // computed and shown nowhere.
        XCTAssertFalse(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .idle,
                                              metaProblems: 1))
        XCTAssertFalse(NeedsAttention.isEmpty(
            conflicts: 0, malformedDecks: 0,
            status: .failed(message: SheetsError.notShared.description, needsAttention: true)))
    }
}
