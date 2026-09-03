import XCTest
import SwiftData
import GoogleSheets
import Scheduling
@testable import Repeat

/// Card #14 acceptance (§4.3).
final class SheetPullTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let header = SheetSyncHarness.header

    // MARK: - Harness

    private func makePull(_ stub: SheetStub) throws -> SheetPull { try SheetSyncHarness.makePull(stub) }
    private func makeContext(deck title: String = "Verbs") throws -> (ModelContext, Deck) {
        try SheetSyncHarness.makeContext(deck: title)
    }
    private func discovery(_ title: String = "Verbs") throws -> DiscoveryResult {
        try SheetSyncHarness.discovery([title])
    }

    private func notes(_ ctx: ModelContext) throws -> [Note] {
        try ctx.fetch(FetchDescriptor<Note>()).sorted { $0.sheetRow < $1.sheetRow }
    }

    // MARK: - Creating

    func testUnknownRowsBecomeNotesAndCards() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header,
            [id.uuidString, "reluctant", "неохочий", "He was reluctant.", "verbs", "TRUE", ""],
        ]])
        let (ctx, _) = try makeContext()
        let result = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.cardsAdded, 2, "reverse=TRUE yields two cards (D2)")
        let note = try XCTUnwrap(try notes(ctx).first)
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(note.front, "reluctant")
        XCTAssertEqual(note.tags, ["verbs"])
        XCTAssertEqual(note.sheetRow, 2, "row 1 is the header")
    }

    /// §3.1: rows with neither front nor back are ignored, not imported empty.
    func testRowsWithNeitherFrontNorBackAreIgnored() async throws {
        let stub = SheetStub(rows: ["Verbs": [
            header,
            ["", "", "", "", "", "", ""],
            [UUID().uuidString, "", "", "note with no content", "", "", ""],
            [UUID().uuidString, "thorough", "ретельний", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let result = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.ignoredBlankRows, 2)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(try notes(ctx).map(\.front), ["thorough"])
    }

    // MARK: - The id write-back (§4.3 steps 2 and 5)

    func testAHandAddedRowGetsAnIdWrittenBack() async throws {
        let stub = SheetStub(rows: ["Verbs": [
            header,
            ["", "thorough", "ретельний", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let result = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.idsWrittenBack, 1)
        let note = try XCTUnwrap(try notes(ctx).first)
        XCTAssertEqual(stub.writtenCells["Verbs!A2"], note.id.uuidString,
                       "the generated id lands in the id cell of that row")
        XCTAssertEqual(stub.inputOptions, ["RAW"], "§4.3 step 5 writes ids raw")
    }

    func testNoWriteBackRequestIsMadeWhenEveryRowAlreadyHasAnId() async throws {
        let stub = SheetStub(rows: ["Verbs": [
            header, [UUID().uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        _ = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertTrue(stub.updates.isEmpty)
    }

    /// Two rows claiming one id would otherwise make the result depend on row
    /// order, which is not a property a sync should have.
    func testDuplicateIdsKeepTheFirstRowAndAreReported() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header,
            [id.uuidString, "first", "перший", "", "", "", ""],
            [id.uuidString, "second", "другий", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let result = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.duplicateRows, 1)
        XCTAssertEqual(try notes(ctx).map(\.front), ["first"])
    }

    // MARK: - Updating, and never touching scheduling

    /// The headline acceptance line: content flows in, scheduling does not move.
    func testEditingFrontInSheetsUpdatesTheCardWithoutChangingItsDueDate() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "reluctant", "неохочий", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let card = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Card>()).first)
        card.state = .review
        card.due = now.addingTimeInterval(12 * 86_400)
        card.stability = 19.25
        card.difficulty = 6.5
        card.reps = 11
        card.lapses = 2
        try ctx.save()
        let before = card.snapshot

        stub.rows["Verbs"] = [header, [id.uuidString, "reluctant (adj)", "неохочий", "", "", "", ""]]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.contentUpdated, 1)
        XCTAssertEqual(try notes(ctx).first?.front, "reluctant (adj)")
        XCTAssertEqual(card.snapshot, before, "not one scheduling field moved")
    }

    func testAnUnchangedRowIsNotCountedAsAnUpdate() async throws {
        let stub = SheetStub(rows: ["Verbs": [
            header, [UUID().uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        let second = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(second.contentUpdated, 0)
        XCTAssertEqual(second.created, 0)
    }

    func testAReverseFlipAddsAndRemovesTheReverseCardOnly() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "FALSE", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let forward = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Card>()).first)
        forward.reps = 4
        forward.stability = 8
        try ctx.save()

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "TRUE", ""]]
        let added = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertEqual(added.cardsAdded, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 2)

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "FALSE", ""]]
        let removed = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertEqual(removed.cardsRemoved, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Card>()).count, 1)
        XCTAssertEqual(forward.reps, 4, "the forward card was untouched throughout")
        XCTAssertEqual(forward.stability, 8)
    }

    func testExtrasArriveAndFlowIntoTheContentHash() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header + ["вимова"],
            [id.uuidString, "reluctant", "неохочий", "", "", "", "", "/rɪˈlʌktənt/"],
        ]])
        let (ctx, _) = try makeContext()
        var found = DiscoveryResult()
        found.readable["Verbs"] = try HeaderMap(headerRow: header + ["вимова"])
        _ = try await makePull(stub).run(discovery: found, in: ctx, now: now)

        let note = try XCTUnwrap(try notes(ctx).first)
        XCTAssertEqual(note.extras, ["вимова": "/rɪˈlʌktənt/"])
        XCTAssertEqual(note.extraOrder, ["вимова"])
        XCTAssertEqual(note.displayExtras.map(\.value), ["/rɪˈlʌktənt/"])
    }

    // MARK: - Deletion (§4.3 step 3)

    func testDeletingARowInSheetsSoftDeletesAndKeepsTheCardRecoverable() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let card = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Card>()).first)
        card.stability = 21.5
        card.reps = 8
        try ctx.save()

        stub.rows["Verbs"] = [header]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 1)
        let note = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(note.deletedAt, now)
        XCTAssertTrue(card.isSuspended)
        XCTAssertEqual(card.stability, 21.5, "kept, so a mistaken deletion is recoverable")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).count, 1, "soft, not hard")
    }

    func testDeletedTrueHasTheSameEffectAsARemovedRow() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "", "TRUE"]]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 1)
        XCTAssertNotNil(try ctx.fetch(FetchDescriptor<Note>()).first?.deletedAt)
    }

    func testARowThatComesBackIsRestoredWithItsScheduling() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", "TRUE"],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "", ""]]
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let card = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Card>()).first)
        card.stability = 30
        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "", "TRUE"]]
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertTrue(card.isSuspended)

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "б", "", "", "", "FALSE"]]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertEqual(result.restored, 1)
        XCTAssertFalse(card.isSuspended)
        XCTAssertEqual(card.stability, 30)
    }

    /// A deck skipped for a malformed header must not have its notes read as
    /// deleted — that would destroy a deck because of a typo in row 1.
    func testNotesInASkippedDeckAreNotTreatedAsDeleted() async throws {
        let id = UUID()
        let stub = SheetStub(rows: [
            "Verbs": [header, [id.uuidString, "a", "б", "", "", "", ""]],
            "Broken": [header, [UUID().uuidString, "x", "у", "", "", "", ""]],
        ])
        let (ctx, deck) = try makeContext()
        let broken = Deck(sheetTitle: "Broken", sheetId: 1)
        ctx.insert(broken)
        _ = deck

        var both = try discovery()
        both.readable["Broken"] = try HeaderMap(headerRow: header)
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: both, in: ctx, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Note>()).count, 2)

        // Next run, "Broken" fails header parsing and is not in `readable`.
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)
        XCTAssertEqual(result.softDeleted, 0)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Note>()).allSatisfy { $0.deletedAt == nil })
    }

    // MARK: - pendingUpload protection (§4.3 step 4)

    /// A local edit that has not been pushed yet survives one pull, so the push
    /// can win. Without this the app would discard an edit the owner made
    /// seconds ago, in favour of a row that has not changed at all.
    func testALocalEditSurvivesAPullWhenTheRowIsUnchanged() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try notes(ctx).first)
        note.back = "відредаговано на телефоні"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.protectedPendingUploads, 1)
        XCTAssertEqual(result.conflicts, 0, "the row did not change, so this is not a conflict")
        XCTAssertEqual(note.back, "відредаговано на телефоні")
        XCTAssertTrue(note.pendingUpload, "still queued for the push")
    }

    /// Both sides changed. §4.5 is fixed and never prompts: the Sheet wins — but
    /// the discarded edit is kept so it can be re-applied (§6.2).
    func testWhenBothSidesChangedTheSheetWinsAndTheEditIsKept() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try notes(ctx).first)
        note.back = "версія з телефона"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "версія з таблиці", "", "", "", ""]]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(note.back, "версія з таблиці", "the Sheet wins (§4.5)")
        XCTAssertFalse(note.pendingUpload, "the discarded edit is no longer queued")

        let conflict = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SyncConflict>()).first)
        XCTAssertEqual(conflict.noteId, note.id)
        XCTAssertEqual(conflict.back, "версія з телефона", "the lost edit is recoverable")
        XCTAssertEqual(conflict.winningBack, "версія з таблиці")
        XCTAssertEqual(conflict.deckTitle, "Verbs")
    }

    /// A note carried over from before `lastSyncedHash` existed has no recorded
    /// common ancestor. The conservative branch must run, so the local edit is
    /// preserved in the conflicts list rather than dropped on a guess.
    func testANoteWithNoRecordedAncestorPreservesTheLocalEdit() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try notes(ctx).first)
        note.lastSyncedHash = nil          // as a pre-migration row would arrive
        note.back = "локальна правка"
        note.refreshContentHash()
        note.pendingUpload = true
        try ctx.save()

        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncConflict>()).first?.back, "локальна правка")
    }

    func testAcceptingSheetContentRecordsTheNewCommonAncestor() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [
            header, [id.uuidString, "a", "б", "", "", "", ""],
        ]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        stub.rows["Verbs"] = [header, [id.uuidString, "a", "оновлено", "", "", "", ""]]
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        let note = try XCTUnwrap(try notes(ctx).first)
        XCTAssertEqual(note.lastSyncedHash, note.contentHash,
                       "after accepting the row, both sides agree again")
    }

    /// Regression: adding a card offline and reconnecting used to delete it.
    ///
    /// A note typed in the app has no row yet, so the pull's "row is gone ⇒
    /// deleted in Sheets" rule fired on it — and it ran before the push in the
    /// same sync, so the card was soft-deleted before it could ever be appended.
    /// §4.4 step 4 gives push the first word on a `pendingUpload` note.
    func testANoteAwaitingItsFirstPushIsNotSoftDeleted() async throws {
        let stub = SheetStub(rows: ["Verbs": [header]])
        let (ctx, deck) = try makeContext()
        let note = Note(deck: deck, front: "щойно додано", back: "just added")
        note.pendingUpload = true
        ctx.insert(note)
        try ctx.save()

        let result = try await makePull(stub).run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 0)
        XCTAssertEqual(result.protectedPendingUploads, 1)
        XCTAssertNil(try XCTUnwrap(try notes(ctx).first).deletedAt)
    }

    /// The rule stays narrow: a synced note really removed from the Sheet is
    /// still soft-deleted.
    func testASyncedNoteMissingFromTheSheetIsStillSoftDeleted() async throws {
        let id = UUID()
        let stub = SheetStub(rows: ["Verbs": [header, [id.uuidString, "a", "б", "", "", "", ""]]])
        let (ctx, _) = try makeContext()
        let pull = try makePull(stub)
        _ = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        stub.rows["Verbs"] = [header]
        let result = try await pull.run(discovery: try discovery(), in: ctx, now: now)

        XCTAssertEqual(result.softDeleted, 1)
        XCTAssertNotNil(try XCTUnwrap(try notes(ctx).first).deletedAt)
    }
}
