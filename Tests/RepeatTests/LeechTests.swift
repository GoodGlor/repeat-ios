import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #34 — leeches: detected, taken out of the session, and fixable.
final class LeechTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let threshold = AppSettings.defaultLeechThreshold

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    @discardableResult
    private func makeNote(
        _ front: String, lapses: Int, suspended: Bool = false,
        reverse: Bool = false, in context: ModelContext, deck: Deck, row: Int = 1
    ) throws -> Note {
        let note = Note(deck: deck, front: front, back: "переклад", reverse: reverse, sheetRow: row)
        context.insert(note)
        for card in context.syncCards(for: note, now: now) {
            card.state = .review
            card.lapses = lapses
            card.stability = 12
            card.difficulty = 7
            card.isSuspended = suspended
        }
        try context.save()
        return note
    }

    // MARK: - Detection

    func testTheThresholdIsInclusive() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: threshold, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)

        XCTAssertTrue(Leech.hasCrossedThreshold(card, threshold: threshold))
        card.lapses = threshold - 1
        XCTAssertFalse(Leech.hasCrossedThreshold(card, threshold: threshold))
    }

    /// Marking suspends and does nothing else. The card's stability is a real
    /// measurement of a real memory; resetting it here would destroy the evidence
    /// that the card is a problem.
    func testMarkingOnlySuspends() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: threshold, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)
        let before = card.snapshot

        XCTAssertTrue(Leech.markIfNeeded(card, threshold: threshold))
        XCTAssertTrue(card.isSuspended)
        XCTAssertEqual(card.stability, before.stability)
        XCTAssertEqual(card.difficulty, before.difficulty)
        XCTAssertEqual(card.lapses, before.lapses)
        XCTAssertEqual(card.due, before.due)
    }

    func testMarkingAnAlreadySuspendedCardChangesNothing() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: threshold, suspended: true, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)
        XCTAssertFalse(Leech.markIfNeeded(card, threshold: threshold))
    }

    /// Being a leech is derived, so a changed threshold changes the answer —
    /// which is the honest behaviour, since the threshold *is* the definition.
    func testRaisingTheThresholdUnflagsCards() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: 8, suspended: true, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)

        XCTAssertTrue(Leech.isLeech(card, threshold: 8))
        XCTAssertFalse(Leech.isLeech(card, threshold: 12))
    }

    func testDeletedNotesAndDecksAreNotListed() throws {
        let (context, deck) = try makeStore()
        let gone = try makeNote("gone", lapses: 12, suspended: true, in: context, deck: deck, row: 1)
        gone.deletedAt = now
        try makeNote("live", lapses: 12, suspended: true, in: context, deck: deck, row: 2)
        try context.save()

        XCTAssertEqual(Leech.all(in: context, threshold: threshold).map(\.note.front), ["live"])

        deck.deletedAt = now
        try context.save()
        XCTAssertTrue(Leech.all(in: context, threshold: threshold).isEmpty)
    }

    func testWorstFirst() throws {
        let (context, deck) = try makeStore()
        try makeNote("mild", lapses: 8, suspended: true, in: context, deck: deck, row: 1)
        try makeNote("awful", lapses: 20, suspended: true, in: context, deck: deck, row: 2)
        try makeNote("bad", lapses: 12, suspended: true, in: context, deck: deck, row: 3)

        XCTAssertEqual(Leech.all(in: context, threshold: threshold).map(\.note.front),
                       ["awful", "bad", "mild"])
    }

    // MARK: - Leaving the queue immediately

    /// The acceptance criterion: not next session — this one.
    func testCrossingTheThresholdRemovesTheCardFromTheLiveSession() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: threshold - 1, in: context, deck: deck, row: 1)
        try makeNote("b", lapses: 0, in: context, deck: deck, row: 2)
        let leechCard = try XCTUnwrap(note.cards.first)
        for card in (try context.fetch(FetchDescriptor<Card>())) { card.due = now.addingTimeInterval(-60) }
        try context.save()

        let plan = QueuePlan(
            cardIds: (try context.fetch(FetchDescriptor<Card>())).map(\.id),
            dueReviewCount: 2, newCardCount: 0, secondsPerCard: 20, studyDay: now
        )
        let session = StudySession(context: context, plan: plan, decks: [deck],
                                   leechThreshold: threshold)

        // Drive the session until the leech card is in front, then fail it.
        var guardRail = 0
        while session.current?.id != leechCard.id, guardRail < 10 {
            session.reveal(now: now)
            session.rate(.good, now: now)
            guardRail += 1
        }
        XCTAssertEqual(session.current?.id, leechCard.id)

        session.reveal(now: now)
        session.rate(.again, now: now)

        XCTAssertTrue(leechCard.isSuspended)
        XCTAssertEqual(session.becameLeech, leechCard.id)
        XCTAssertNotEqual(session.current?.id, leechCard.id,
                          "an .again would normally bring it straight back as a relearning card")
    }

    /// An undo has to undo the leech mark too, or the card is gone for good on a
    /// misgrade.
    func testUndoTakesBackTheLeechMark() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: threshold - 1, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)
        card.due = now.addingTimeInterval(-60)
        try context.save()

        let plan = QueuePlan(cardIds: [card.id], dueReviewCount: 1, newCardCount: 0,
                             secondsPerCard: 20, studyDay: now)
        let session = StudySession(context: context, plan: plan, decks: [deck],
                                   leechThreshold: threshold)
        session.reveal(now: now)
        session.rate(.again, now: now)
        XCTAssertTrue(card.isSuspended)

        XCTAssertTrue(session.undo(now: now))
        XCTAssertFalse(card.isSuspended, "the snapshot carried the unsuspended state")
        XCTAssertEqual(card.lapses, threshold - 1)
        XCTAssertNil(session.becameLeech)
        XCTAssertEqual(session.current?.id, card.id, "and it is back in front of the person")
    }

    // MARK: - Rewrite

    /// The acceptance criterion: back to normal scheduling **with its stability
    /// intact**. The person's memory did not reset because the prompt was
    /// reworded.
    func testRewriteClearsLapsesAndUnsuspendsButKeepsTheMemory() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: 12, suspended: true, in: context, deck: deck)
        let card = try XCTUnwrap(note.cards.first)
        let stability = card.stability
        let difficulty = card.difficulty
        let due = card.due

        try Leech.rewrite(note, in: context, now: now)

        XCTAssertEqual(card.lapses, 0)
        XCTAssertFalse(card.isSuspended)
        XCTAssertEqual(card.stability, stability)
        XCTAssertEqual(card.difficulty, difficulty)
        XCTAssertEqual(card.due, due)
        XCTAssertTrue(Leech.all(in: context, threshold: threshold).isEmpty)
    }

    /// The wording is the Sheet's to own, so an edit has to reach it by the
    /// ordinary route.
    func testRewriteQueuesTheNoteForThePush() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: 12, suspended: true, in: context, deck: deck)
        note.pendingUpload = false

        try Leech.rewrite(note, in: context, now: now)

        XCTAssertTrue(note.pendingUpload)
        XCTAssertEqual(note.updatedAt, now)
    }

    /// A reversed note was rewritten by one edit, so both its cards come back.
    func testRewriteAppliesToBothDirections() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: 12, suspended: true, reverse: true,
                                in: context, deck: deck)
        XCTAssertEqual(note.cards.count, 2)

        try Leech.rewrite(note, in: context, now: now)
        XCTAssertTrue(note.cards.allSatisfy { $0.lapses == 0 && !$0.isSuspended })
    }

    // MARK: - Delete

    /// §5.4: "soft-deletes the note through the normal push path" — not a local
    /// removal. The row exists in someone's spreadsheet.
    func testDeleteMarksTheNoteAndQueuesIt() throws {
        let (context, deck) = try makeStore()
        let note = try makeNote("a", lapses: 12, suspended: true, in: context, deck: deck)

        try Leech.delete(note, in: context, now: now)

        XCTAssertEqual(note.deletedAt, now)
        XCTAssertTrue(note.pendingUpload)
        XCTAssertFalse((try context.fetch(FetchDescriptor<Note>())).isEmpty,
                       "a hard delete would lose the row the Sheet still has")
        XCTAssertTrue(Leech.all(in: context, threshold: threshold).isEmpty)
    }

    // MARK: - Home's section

    func testTheSectionStaysHiddenUntilThereIsALeech() {
        XCTAssertTrue(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0, status: .idle))
        XCTAssertFalse(NeedsAttention.isEmpty(conflicts: 0, malformedDecks: 0,
                                              status: .idle, leeches: 1))
    }

    func testTheCountReadsAsUkrainian() {
        XCTAssertEqual(NeedsAttention.leechTitle(count: 1, locale: Locale(identifier: "uk")), "1 картка постійно забувається")
        // Was asserted as "3 карток" — the hand-rolled `count == 1 ? … : …` got
        // 2-4 wrong and this test locked the mistake in. Fixed by #38.
        XCTAssertEqual(NeedsAttention.leechTitle(count: 3, locale: Locale(identifier: "uk")), "3 картки постійно забуваються")
        XCTAssertEqual(NeedsAttention.leechTitle(count: 5, locale: Locale(identifier: "uk")), "5 карток постійно забуваються")
        XCTAssertEqual(NeedsAttention.leechTitle(count: 21, locale: Locale(identifier: "uk")), "21 картка постійно забувається")
    }
}
