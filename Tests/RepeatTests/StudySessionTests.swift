import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// Card #6 acceptance, minus the pixels: a full session runs end to end, and a
/// rating cannot be submitted before the answer has been revealed.
final class StudySessionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(cards: Int = 3, reverse: Bool = false) throws -> (ModelContext, StudySession, [Deck]) {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 1, newCardsPerDay: 50)
        ctx.insert(deck)
        for row in 0..<cards {
            let note = Note(deck: deck, front: "f\(row)", back: "b\(row)", reverse: reverse, sheetRow: row)
            ctx.insert(note)
            ctx.syncCards(for: note, now: now)
        }
        try ctx.save()

        var generator = SystemRandomNumberGenerator()
        let plan = QueueBuilder.plan(decks: [deck], now: now, using: &generator)
        return (ctx, StudySession(context: ctx, plan: plan, decks: [deck]), [deck])
    }

    // MARK: - The reveal gate

    func testRatingIsIgnoredBeforeReveal() throws {
        let (ctx, session, _) = try makeSession()
        let card = try XCTUnwrap(session.current)
        let before = card.snapshot

        session.rate(.good, now: now)

        XCTAssertEqual(card.snapshot, before, "an unrevealed card must not be graded")
        XCTAssertEqual(session.current?.id, card.id, "and the queue must not advance")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 0, "no log row either")
    }

    func testPreviewsOnlyExistOnceRevealed() throws {
        let (_, session, _) = try makeSession()
        XCTAssertTrue(session.previews.isEmpty)
        session.reveal(now: now)
        XCTAssertTrue(session.isRevealed)
        XCTAssertEqual(Set(session.previews.keys), Set(Grade.allCases))
    }

    func testRevealResetsForEachCard() throws {
        let (_, session, _) = try makeSession()
        session.reveal(now: now)
        session.rate(.easy, now: now)
        XCTAssertFalse(session.isRevealed, "the next card starts face down")
        XCTAssertTrue(session.previews.isEmpty)
    }

    // MARK: - A full session

    func testAFullSessionCompletesAndReportsASummary() throws {
        let (ctx, session, _) = try makeSession(cards: 4)
        XCTAssertEqual(session.total, 4)

        var guard_ = 0
        while session.current != nil, guard_ < 50 {
            guard_ += 1
            session.reveal(now: now)
            // Easy graduates immediately, so nothing returns as a learning step.
            session.rate(.easy, now: now)
        }

        XCTAssertNil(session.current)
        XCTAssertEqual(session.summary, .init(reviewed: 4, forgotten: 0))
        XCTAssertEqual(session.completed, 4)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReviewLog>()).count, 4)
    }

    func testAgainCountsAsForgottenAndTheCardComesBackInTheSameSession() throws {
        let (_, session, _) = try makeSession(cards: 1)
        let card = try XCTUnwrap(session.current)

        session.reveal(now: now)
        session.rate(.again, now: now)

        XCTAssertNil(session.current, "the 1m step has not elapsed yet")
        XCTAssertNotNil(session.waitingUntil)
        XCTAssertNil(session.summary, "the session is not over while a step is pending")

        // Once the step elapses the card returns.
        session.refresh(now: card.due)
        XCTAssertEqual(session.current?.id, card.id)

        session.reveal(now: card.due)
        session.rate(.easy, now: card.due)
        XCTAssertEqual(session.summary?.forgotten, 1)
        XCTAssertEqual(session.summary?.reviewed, 2, "two answers, one card")
    }

    func testProgressNeverExceedsTheTotal() throws {
        let (_, session, _) = try makeSession(cards: 2)
        var guard_ = 0
        while guard_ < 30 {
            guard_ += 1
            guard let card = session.current else {
                guard let until = session.waitingUntil else { break }
                session.refresh(now: until)
                continue
            }
            session.reveal(now: card.due)
            session.rate(guard_ == 1 ? .again : .easy, now: card.due)
            XCTAssertLessThanOrEqual(session.completed, session.total)
            XCTAssertLessThanOrEqual(session.progress, 1.0)
        }
        XCTAssertNotNil(session.summary)
    }

    func testBothDirectionsOfAReverseNoteAreStudiedSeparately() throws {
        let (_, session, _) = try makeSession(cards: 1, reverse: true)
        XCTAssertEqual(session.total, 2)
        var seen: Set<String> = []
        var guard_ = 0
        while let card = session.current, guard_ < 10 {
            guard_ += 1
            seen.insert(card.direction.rawValue)
            session.reveal(now: now)
            session.rate(.easy, now: now)
        }
        XCTAssertEqual(seen, ["fwd", "rev"])
    }

    // MARK: - Store writes

    func testRatingPersistsSchedulingAndTheLogRow() throws {
        let (ctx, session, _) = try makeSession(cards: 1)
        let card = try XCTUnwrap(session.current)

        session.reveal(now: now)
        session.rate(.good, now: now)

        XCTAssertEqual(card.state, .learning)
        XCTAssertEqual(card.reps, 1)
        let log = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ReviewLog>()).first)
        XCTAssertEqual(log.cardId, card.id)
        XCTAssertEqual(log.rating, Grade.good.rawValue)
        XCTAssertEqual(log.stateBefore, .new)
    }

    /// The button label has to be what the tap does — the point of routing both
    /// through one scheduler call.
    func testTheLabelShownIsTheIntervalApplied() throws {
        let (_, session, _) = try makeSession(cards: 1)
        let card = try XCTUnwrap(session.current)
        session.reveal(now: now)
        let promised = try XCTUnwrap(session.previews[.good])

        session.rate(.good, now: now)
        XCTAssertEqual(card.due, promised.due, "button read \(promised.label)")
    }

    // MARK: - Sample data

    func testSampleDeckSeedsOnceAndIsStudiable() throws {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = try XCTUnwrap(SampleData.seedIfEmpty(ctx))
        XCTAssertEqual(deck.notes.count, 8)
        XCTAssertEqual(deck.notes.flatMap(\.cards).count, 10, "two notes are reverse")

        SampleData.seedIfEmpty(ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Deck>()).count, 1, "seeding twice must not duplicate")
    }
}
