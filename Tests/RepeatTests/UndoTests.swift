import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #7 acceptance (§5.5).
final class UndoTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(cards: Int = 2) throws -> (ModelContext, StudySession) {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 50)
        ctx.insert(deck)
        for row in 0..<cards {
            let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", sheetRow: row)
            ctx.insert(note)
            let made = ctx.syncCards(for: note, now: now)
            // Start as review cards so the scheduling fields being restored are
            // non-trivial rather than all zero.
            for card in made {
                card.state = .review
                card.stability = 14.5 + Double(row)
                card.difficulty = 5.25
                card.reps = 6
                card.lapses = 2
                card.scheduledDays = 14
                card.due = now.addingTimeInterval(-86_400)
                card.lastReview = now.addingTimeInterval(-15 * 86_400)
            }
        }
        try ctx.save()
        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: [deck], now: now, using: &generator)
        return (ctx, StudySession(context: ctx, plan: plan, decks: [deck]))
    }

    // MARK: - Availability

    func testUndoIsUnavailableBeforeTheFirstRating() throws {
        let (_, session) = try makeSession()
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.undo(now: now))
    }

    func testUndoBecomesAvailableAfterARatingAndIsSingleLevel() throws {
        let (_, session) = try makeSession()
        session.reveal(now: now); session.rate(.good, now: now)
        XCTAssertTrue(session.canUndo)

        XCTAssertTrue(session.undo(now: now))
        XCTAssertFalse(session.canUndo, "§5.5 offers the last rating, not a history")
        XCTAssertFalse(session.undo(now: now))
    }

    // MARK: - Restoration

    func testUndoRestoresEverySchedulingFieldExactly() throws {
        let (_, session) = try makeSession()
        let card = try XCTUnwrap(session.current)
        let before = card.snapshot

        session.reveal(now: now)
        session.rate(.again, now: now)
        XCTAssertNotEqual(card.snapshot, before)

        XCTAssertTrue(session.undo(now: now))
        XCTAssertEqual(card.snapshot, before)
        XCTAssertEqual(card.due, before.due)
        XCTAssertEqual(card.stability, before.stability)
        XCTAssertEqual(card.difficulty, before.difficulty)
        XCTAssertEqual(card.reps, before.reps)
        XCTAssertEqual(card.lapses, before.lapses)
    }

    func testUndoPutsTheCardBackAtTheFrontOfTheQueue() throws {
        let (_, session) = try makeSession(cards: 2)
        let first = try XCTUnwrap(session.current)

        session.reveal(now: now); session.rate(.easy, now: now)
        XCTAssertNotEqual(session.current?.id, first.id, "moved on to the second card")

        session.undo(now: now)
        XCTAssertEqual(session.current?.id, first.id)
        XCTAssertFalse(session.isRevealed, "the restored card comes back face down")
    }

    func testUndoRewindsTheSessionCounters() throws {
        let (_, session) = try makeSession(cards: 2)
        session.reveal(now: now); session.rate(.again, now: now)
        XCTAssertEqual(session.completed, 1)

        session.undo(now: now)
        XCTAssertEqual(session.completed, 0)

        // And the Again is no longer counted as forgotten.
        session.reveal(now: now); session.rate(.easy, now: now)
        session.reveal(now: now); session.rate(.easy, now: now)
        XCTAssertEqual(session.summary, .init(reviewed: 2, forgotten: 0))
    }

    /// Otherwise the last card of a session is the one card that can never be
    /// corrected.
    func testUndoReopensAFinishedSession() throws {
        let (_, session) = try makeSession(cards: 1)
        session.reveal(now: now); session.rate(.easy, now: now)
        XCTAssertNotNil(session.summary)

        session.undo(now: now)
        XCTAssertNil(session.summary)
        XCTAssertNotNil(session.current)
    }

    // MARK: - The log

    func testUndoOfANotYetUploadedReviewDeletesItsLogRow() throws {
        let (ctx, session) = try makeSession(cards: 1)
        session.reveal(now: now); session.rate(.good, now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 1)

        session.undo(now: now)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 0,
                       "nothing was pushed, so there is nothing to reverse")
    }

    func testUndoOfAnUploadedReviewAppendsExactlyOneUndoMarker() throws {
        let (ctx, session) = try makeSession(cards: 1)
        let card = try XCTUnwrap(session.current)
        session.reveal(now: now); session.rate(.good, now: now)

        // The push has happened since (§4.4).
        let uploaded = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ReviewLog>()).first)
        uploaded.uploaded = true
        try ctx.save()

        session.undo(now: now)

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.count, 2, "the original row stays; the reversal is its own row")
        let markers = logs.filter { $0.rating == 0 }
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.cardId, card.id)
        XCTAssertEqual(marker.direction, card.direction)
        XCTAssertFalse(marker.uploaded, "the marker still needs pushing")
        XCTAssertTrue(logs.contains { $0.rating == Grade.good.rawValue && $0.uploaded })
    }

    /// Rating 0 is not a grade. #41's replay and §5.2's time estimate both skip
    /// it, so it must never be mistaken for a review.
    func testUndoMarkersAreNotGradesAndAreExcludedFromEstimates() throws {
        let (ctx, session) = try makeSession(cards: 1)
        session.reveal(now: now); session.rate(.good, now: now)
        let uploaded = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ReviewLog>()).first)
        uploaded.uploaded = true
        session.undo(now: now)

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertNil(Grade(rawValue: 0), "0 is deliberately not expressible as a Grade")
        XCTAssertEqual(QueueBuilder.secondsPerCard(from: logs), 20,
                       "one real review plus a marker is not two reviews")
    }

    func testRatingAgainAfterUndoLeavesOneReviewInTheLog() throws {
        let (ctx, session) = try makeSession(cards: 1)
        session.reveal(now: now); session.rate(.good, now: now)
        session.undo(now: now)
        session.reveal(now: now); session.rate(.hard, now: now)

        let logs = try ctx.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.rating, Grade.hard.rawValue)
    }
}
