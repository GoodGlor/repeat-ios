import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// The app-side half of card #4: the bridge between the SwiftData model and the
/// `Scheduling` package's value types.
final class CardSchedulingTests: XCTestCase {

    private func makeCard() throws -> (ModelContext, Card) {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1)
        ctx.insert(deck)
        let note = Note(deck: deck, front: "reluctant", back: "неохочий")
        ctx.insert(note)
        return (ctx, try XCTUnwrap(ctx.syncCards(for: note).first))
    }

    func testSnapshotRoundTripsThroughTheModel() throws {
        let (_, card) = try makeCard()
        card.state = .review
        card.due = Date(timeIntervalSince1970: 1_800_000_000)
        card.stability = 12.5
        card.difficulty = 6.25
        card.elapsedDays = 4
        card.scheduledDays = 12
        card.reps = 8
        card.lapses = 2
        card.lastReview = Date(timeIntervalSince1970: 1_799_000_000)
        card.learningStepIndex = 1
        card.isSuspended = true

        let snapshot = card.snapshot
        card.restore(from: CardSchedulingSnapshot())
        XCTAssertEqual(card.state, .new)
        card.restore(from: snapshot)
        XCTAssertEqual(card.snapshot, snapshot)
    }

    func testRatingUpdatesTheCardAndWritesAMatchingLogRow() throws {
        let (ctx, card) = try makeCard()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let before = card.snapshot

        let log = try ctx.rate(card, .good, with: Scheduler(), now: now)
        try ctx.save()

        XCTAssertEqual(card.state, .learning)
        XCTAssertGreaterThan(card.due, now)
        XCTAssertEqual(card.reps, 1)
        XCTAssertEqual(card.lastReview, now)

        XCTAssertEqual(log.cardId, card.id)
        XCTAssertEqual(log.direction, .forward)
        XCTAssertEqual(log.rating, Grade.good.rawValue)
        XCTAssertEqual(log.reviewedAt, now)
        XCTAssertEqual(log.stateBefore, .new)
        XCTAssertFalse(log.uploaded)
        XCTAssertEqual(try log.decodedPrevState(), before, "undo restores exactly what was there")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 1)
    }

    /// The log row must carry the scheduler's own numbers, not a second derivation
    /// that could drift from them.
    func testLogScheduledDaysMatchTheCardTheSchedulerProduced() throws {
        let (ctx, card) = try makeCard()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        card.state = .review
        card.stability = 20
        card.difficulty = 5
        card.scheduledDays = 20
        card.reps = 5
        card.lastReview = now.addingTimeInterval(-20 * 86_400)

        let log = try ctx.rate(card, .easy, with: Scheduler(), now: now)
        XCTAssertEqual(log.scheduledDays, card.scheduledDays)
        XCTAssertEqual(log.elapsedDays, 20)
    }

    func testTheButtonLabelIsWhatTheRatingActuallyDoes() throws {
        let (ctx, card) = try makeCard()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = Scheduler()

        let promised = try XCTUnwrap(try scheduler.preview(for: card.snapshot, now: now)[.good])
        try ctx.rate(card, .good, with: scheduler, now: now)
        XCTAssertEqual(card.due, promised.due, "the study screen showed \(promised.label)")
    }
}
