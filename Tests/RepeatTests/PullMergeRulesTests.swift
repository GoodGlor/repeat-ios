import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// Card #15: every row of §4.5's conflict table, plus the invariant that holds
/// across all of them.
///
/// **§4.5 → test**
/// - Same note edited in Sheet and app since last sync → `testSheetWinsAndTheDiscardedEditIsRecoverable`
/// - Row deleted in Sheet, reviewed on phone meanwhile → `testDeleteWinsAndTheReviewLogSurvives`
/// - Sheet unreachable → `testAnUnreachableSheetChangesNothingLocally`
final class PullMergeRulesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let header = SheetSyncHarness.header

    private func seed(
        _ stub: SheetStub, id: UUID, front: String = "reluctant", back: String = "неохочий"
    ) throws -> (ModelContext, SheetPull) {
        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: front, back: back)]
        let (ctx, _) = try SheetSyncHarness.makeContext()
        return (ctx, try SheetSyncHarness.makePull(stub))
    }

    private func study(_ ctx: ModelContext, at when: Date) throws -> (Card, ReviewLog) {
        let card = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Card>()).first)
        let log = try ctx.rate(card, .good, with: Scheduler(), now: when)
        try ctx.save()
        return (card, log)
    }

    // MARK: - Row 1: both sides edited

    func testSheetWinsAndTheDiscardedEditIsRecoverable() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first)
        note.back = "телефон"
        note.example = "приклад із телефона"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: "reluctant", back: "таблиця")]
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(note.back, "таблиця")

        let conflict = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SyncConflict>()).first)
        XCTAssertEqual(conflict.back, "телефон")
        XCTAssertEqual(conflict.example, "приклад із телефона")
        XCTAssertEqual(conflict.winningBack, "таблиця")
        XCTAssertEqual(conflict.occurredAt, now)
    }

    func testSeveralConflictsAreAllKeptRatherThanTheLastOneWinning() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let stub = SheetStub(rows: ["Verbs": [header] + ids.enumerated().map {
            SheetSyncHarness.row($0.element, front: "f\($0.offset)", back: "b\($0.offset)")
        }])
        let (ctx, _) = try SheetSyncHarness.makeContext()
        let pull = try SheetSyncHarness.makePull(stub)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        for note in try ctx.fetch(FetchDescriptor<Note>()) {
            note.back = "локально \(note.front)"
            note.refreshContentHash()
            note.pendingUpload = true
        }
        try ctx.save()

        stub.rows["Verbs"] = [header] + ids.enumerated().map {
            SheetSyncHarness.row($0.element, front: "f\($0.offset)", back: "таблиця \($0.offset)")
        }
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.conflicts, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncConflict>()).count, 3)
    }

    // MARK: - Row 2: deleted in the Sheet, reviewed on the phone

    /// The review happened; the row is gone. The delete wins, but the log is the
    /// optimizer's input and #41's replay history — losing it would silently
    /// degrade future scheduling for every card.
    func testDeleteWinsAndTheReviewLogSurvives() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        let (card, log) = try study(ctx, at: now)
        let cardId = card.id
        let reviewedAt = log.reviewedAt

        stub.rows["Verbs"] = [header]
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 1)
        XCTAssertNotNil(try ctx.fetch(FetchDescriptor<Note>()).first?.deletedAt)
        XCTAssertTrue(card.isSuspended)

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.count, 1, "the review still happened")
        XCTAssertEqual(logs.first?.cardId, cardId)
        XCTAssertEqual(logs.first?.reviewedAt, reviewedAt)
        XCTAssertFalse(logs.first?.uploaded ?? true, "still queued for _log (§4.4)")
    }

    func testAPendingLocalEditLosesToADeleteRatherThanResurrectingTheRow() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first)
        note.back = "локальна правка"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: "reluctant", back: "неохочий", deleted: true)]
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 1)
        XCTAssertNotNil(note.deletedAt, "delete wins (§4.5)")
    }

    // MARK: - Row 3: the Sheet is unreachable

    /// Offline must be inert. Anything else means a flaky connection can lose an
    /// edit the owner has already made.
    func testAnUnreachableSheetChangesNothingLocally() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first)
        note.back = "локальна правка"
        note.refreshContentHash()
        note.pendingUpload = true
        let (card, _) = try study(ctx, at: now)
        let cardBefore = card.snapshot
        let noteBefore = note.contentHash
        try ctx.save()

        stub.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
            XCTFail("expected the pull to fail")
        } catch {
            // Expected — §4.2 queues and retries on the next trigger.
        }

        XCTAssertEqual(note.contentHash, noteBefore, "the local edit is untouched")
        XCTAssertTrue(note.pendingUpload, "still queued to push")
        XCTAssertEqual(card.snapshot, cardBefore)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 1, "the review is still queued")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncConflict>()).count, 0)
    }

    func testWorkQueuedWhileOfflineIsAppliedOnceTheSheetIsReachableAgain() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        stub.failure = URLError(.timedOut)
        _ = try? await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        stub.failure = nil
        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: "reluctant", back: "оновлено")]
        let result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        XCTAssertEqual(result.contentUpdated, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).first?.back, "оновлено")
    }

    // MARK: - pendingUpload protection holds for exactly one pull

    /// "Push wins once, then normal rules apply" (§4.3 step 4). If the protection
    /// were permanent, a note edited on the phone would stop receiving Sheet
    /// updates forever.
    func testProtectionLastsUntilThePushClearsTheFlagAndNoLonger() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first)
        note.back = "локально"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        // Pull with an unchanged row: the local edit survives.
        var result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result.protectedPendingUploads, 1)
        XCTAssertEqual(note.back, "локально")

        // The push then succeeds, so both sides agree on the local content (§4.4).
        note.pendingUpload = false
        note.lastSyncedHash = note.contentHash
        try ctx.save()

        // A later Sheet edit now applies normally.
        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: "reluctant", back: "з таблиці")]
        result = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(result.protectedPendingUploads, 0)
        XCTAssertEqual(result.conflicts, 0)
        XCTAssertEqual(note.back, "з таблиці")
    }

    // MARK: - The invariant

    /// Every §4.5 scenario, run against a card with real scheduling state, with
    /// the full snapshot compared before and after. This is the acceptance line
    /// "no test mutates Card scheduling fields through a pull path" expressed as
    /// an assertion rather than a review convention.
    func testSchedulingStateIsInvariantAcrossEveryPullScenario() async throws {
        let scenarios: [(name: String, mutate: (SheetStub, UUID, Note) -> Void)] = [
            ("unchanged row", { _, _, _ in }),
            ("content edited in the Sheet", { stub, id, _ in
                stub.rows["Verbs"] = [SheetSyncHarness.header,
                                      SheetSyncHarness.row(id, front: "змінено", back: "б")]
            }),
            ("row deleted in the Sheet", { stub, _, _ in
                stub.rows["Verbs"] = [SheetSyncHarness.header]
            }),
            ("deleted=TRUE", { stub, id, _ in
                stub.rows["Verbs"] = [SheetSyncHarness.header,
                                      SheetSyncHarness.row(id, front: "a", back: "б", deleted: true)]
            }),
            ("reverse turned on", { stub, id, _ in
                stub.rows["Verbs"] = [SheetSyncHarness.header,
                                      SheetSyncHarness.row(id, front: "a", back: "б", reverse: true)]
            }),
            ("conflicting edits", { stub, id, note in
                note.back = "локально"
                note.refreshContentHash()
                note.pendingUpload = true
                stub.rows["Verbs"] = [SheetSyncHarness.header,
                                      SheetSyncHarness.row(id, front: "a", back: "з таблиці")]
            }),
            ("id written back for a new row", { stub, id, _ in
                stub.rows["Verbs"] = [SheetSyncHarness.header,
                                      SheetSyncHarness.row(id, front: "a", back: "б"),
                                      ["", "нове", "нова", "", "", "", ""]]
            }),
        ]

        for scenario in scenarios {
            let id = UUID()
            let stub = SheetStub(rows: ["Verbs": [header, SheetSyncHarness.row(id, front: "a", back: "б")]])
            let (ctx, _) = try SheetSyncHarness.makeContext()
            let pull = try SheetSyncHarness.makePull(stub)
            _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

            let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first { $0.id == id })
            let card = try XCTUnwrap(note.cards.first { $0.direction == .forward })
            card.state = .review
            card.due = now.addingTimeInterval(9 * 86_400)
            card.stability = 16.75
            card.difficulty = 5.5
            card.elapsedDays = 9
            card.scheduledDays = 9
            card.reps = 12
            card.lapses = 3
            card.lastReview = now.addingTimeInterval(-9 * 86_400)
            card.learningStepIndex = 0
            try ctx.save()
            let before = card.snapshot

            scenario.mutate(stub, id, note)
            _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)

            var expected = before
            // Soft delete suspends, which is the one scheduling-adjacent effect
            // §4.3 sanctions — and it is reversible.
            if card.isSuspended { expected.isSuspended = true }
            XCTAssertEqual(card.snapshot, expected, "scenario: \(scenario.name)")
        }
    }

    /// The corollary: a pull writes no `_log` rows. Reviews are the only thing
    /// that may, and a sync is not a review.
    func testAPullNeverWritesAReviewLogRow() async throws {
        let id = UUID()
        let stub = SheetStub()
        let (ctx, pull) = try seed(stub, id: id)
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 0)

        stub.rows["Verbs"] = [header, SheetSyncHarness.row(id, front: "змінено", back: "б", reverse: true)]
        _ = try await pull.run(discovery: try SheetSyncHarness.discovery(), in: ctx, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 0)
    }
}
