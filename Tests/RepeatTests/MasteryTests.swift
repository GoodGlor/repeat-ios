import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// §5.3 — known / learning / new, and the words that became known this month.
/// Derived from `Card` and `ReviewLog` on demand, like every number in M9.
final class MasteryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar.current

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now) ?? now
    }

    /// A card in a given state. `reviewedDaysAgo == nil` leaves it new.
    @discardableResult
    private func card(
        _ front: String, state: SchedulingState = .review, stability: Double = 0,
        reviewedDaysAgo: Int? = nil, suspended: Bool = false, reverse: Bool = false,
        in context: ModelContext, deck: Deck
    ) throws -> [Card] {
        let note = Note(deck: deck, front: front, back: "—", reverse: reverse, sheetRow: 0)
        context.insert(note)
        let cards = context.syncCards(for: note, now: now)
        for made in cards {
            made.state = state
            made.stability = stability
            made.isSuspended = suspended
            if let reviewedDaysAgo {
                made.lastReview = daysAgo(reviewedDaysAgo)
                made.reps = 3
            }
        }
        try context.save()
        return cards
    }

    // MARK: - The bucket

    func testKnownIsReviewStateWithStabilityAtLeastTheThreshold() {
        XCTAssertEqual(Mastery.bucket(state: .review, stability: 21, lastReview: now), .known)
        XCTAssertEqual(Mastery.bucket(state: .review, stability: 300, lastReview: now), .known)
    }

    func testJustUnderTheThresholdIsStillLearning() {
        XCTAssertEqual(Mastery.bucket(state: .review, stability: 20.99, lastReview: now), .learning)
    }

    func testAForgottenCardIsLearningHoweverStableItWas() {
        // A lapse puts the card in `.relearning`; the stability it had no longer
        // says it is known.
        XCTAssertEqual(Mastery.bucket(state: .relearning, stability: 40, lastReview: now), .learning)
        XCTAssertEqual(Mastery.bucket(state: .learning, stability: 1, lastReview: now), .learning)
    }

    func testNeverReviewedIsNew() {
        XCTAssertEqual(Mastery.bucket(state: .new, stability: 0, lastReview: nil), .new)
    }

    // MARK: - Counts on a deck

    func testCountsBucketEveryCardOfTheDeck() throws {
        let (context, deck) = try makeStore()
        try card("k1", stability: 25, reviewedDaysAgo: 2, in: context, deck: deck)
        try card("k2", stability: 21, reviewedDaysAgo: 9, in: context, deck: deck)
        try card("l1", stability: 3, reviewedDaysAgo: 1, in: context, deck: deck)
        try card("l2", state: .relearning, stability: 30, reviewedDaysAgo: 1, in: context, deck: deck)
        try card("n1", state: .new, in: context, deck: deck)
        try card("n2", state: .new, in: context, deck: deck)
        try card("n3", state: .new, in: context, deck: deck)
        let cards = try context.fetch(FetchDescriptor<Card>())

        XCTAssertEqual(Mastery.Counts.make(cards: cards), Mastery.Counts(known: 2, learning: 2, new: 3))
        XCTAssertEqual(Mastery.Counts.make(cards: cards).total, 7)
    }

    func testASuspendedCardKeepsItsBucket() throws {
        // Ruling 1: the bar covers the same cards as the count beside it.
        let (context, deck) = try makeStore()
        try card("leech", stability: 1.5, reviewedDaysAgo: 4, suspended: true, in: context, deck: deck)
        try card("k", stability: 30, reviewedDaysAgo: 4, suspended: true, in: context, deck: deck)
        let cards = try context.fetch(FetchDescriptor<Card>())

        XCTAssertEqual(Mastery.Counts.make(cards: cards), Mastery.Counts(known: 1, learning: 1, new: 0))
    }

    func testABothWaysNoteCountsTwoCards() throws {
        let (context, deck) = try makeStore()
        try card("both", state: .new, reverse: true, in: context, deck: deck)
        let cards = try context.fetch(FetchDescriptor<Card>())

        XCTAssertEqual(Mastery.Counts.make(cards: cards), Mastery.Counts(known: 0, learning: 0, new: 2))
    }

    func testNoCardsIsNoCounts() {
        XCTAssertEqual(Mastery.Counts.make(cards: []), .empty)
        XCTAssertEqual(Mastery.Counts.empty.total, 0)
    }

    // MARK: - Became known

    /// A real review of `card` whose `prevState` had `stability` (and `state`),
    /// dated `daysAgo`. The review itself is what the card looks like *after*;
    /// only the snapshot before it matters here.
    @discardableResult
    private func review(
        _ card: Card, daysAgo: Int, minutesLater: Int = 0, rating: Int = Grade.good.rawValue,
        prevStability: Double, prevState: SchedulingState = .review, in context: ModelContext
    ) throws -> ReviewLog {
        let at = self.daysAgo(daysAgo).addingTimeInterval(Double(minutesLater) * 60)
        let log = try ReviewLog(
            cardId: card.id, direction: card.direction, rating: rating, reviewedAt: at,
            elapsedDays: 1, scheduledDays: 1, stateBefore: prevState,
            prevState: CardSchedulingSnapshot(state: prevState, stability: prevStability,
                                              lastReview: at.addingTimeInterval(-86_400))
        )
        context.insert(log)
        try context.save()
        return log
    }

    private func learned(_ context: ModelContext) throws -> [Mastery.LearnedWord] {
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())
        return Mastery.learnedThisMonth(in: context, logs: logs, now: now, calendar: calendar)
    }

    func testACardThatCrossedThisMonthIsListedOnceAtTheCrossing() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("harbour", stability: 30, reviewedDaysAgo: 3, in: context, deck: deck).first)
        try review(made, daysAgo: 10, prevStability: 10, in: context)   // the crossing: 10 → known
        try review(made, daysAgo: 3, prevStability: 25, in: context)    // a later review, already known

        let words = try learned(context)
        XCTAssertEqual(words.map(\.front), ["harbour"])
        XCTAssertEqual(words.first?.learnedAt, daysAgo(10), "dated the review that crossed, not the latest one")
    }

    func testACardKnownSinceLastMonthIsNotListedEvenIfReviewedThisMonth() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("candle", stability: 40, reviewedDaysAgo: 3, in: context, deck: deck).first)
        try review(made, daysAgo: 20, prevStability: 10, in: context)   // crossed 26 December
        try review(made, daysAgo: 3, prevStability: 25, in: context)

        XCTAssertEqual(try learned(context), [])
    }

    func testACardThatWasForgottenAgainIsNotListed() throws {
        // Stability left at 30 on purpose: the SQL prefilter passes this card,
        // and only the in-memory `state == .review` check can exclude it.
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("pebble", state: .relearning, stability: 30, reviewedDaysAgo: 1,
                                      in: context, deck: deck).first)
        try review(made, daysAgo: 6, prevStability: 10, in: context)
        try review(made, daysAgo: 1, rating: Grade.again.rawValue, prevStability: 30, in: context)

        XCTAssertEqual(try learned(context), [], "it is not known now, so it was not learned")
    }

    func testACardThatLapsedAndCameBackIsDatedTheSecondCrossing() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("river", stability: 22, reviewedDaysAgo: 2, in: context, deck: deck).first)
        try review(made, daysAgo: 12, prevStability: 10, in: context)                         // crossed
        try review(made, daysAgo: 8, rating: Grade.again.rawValue, prevStability: 30, in: context) // forgot
        try review(made, daysAgo: 2, prevStability: 6, prevState: .relearning, in: context)   // crossed again

        XCTAssertEqual(try learned(context).map(\.learnedAt), [daysAgo(2)])
    }

    func testAnUndoMarkerIsNotACrossing() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("meadow", stability: 30, reviewedDaysAgo: 5, in: context, deck: deck).first)
        try review(made, daysAgo: 5, prevStability: 10, in: context)                        // crossed
        try review(made, daysAgo: 5, minutesLater: 1, rating: 0, prevStability: 10, in: context) // undo marker: snapshot from before the undone review
        try review(made, daysAgo: 5, minutesLater: 2, prevStability: 10, in: context)      // re-rated
        made.lastReview = daysAgo(5).addingTimeInterval(120)
        try context.save()

        let words = try learned(context)
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words.first?.learnedAt, daysAgo(5).addingTimeInterval(120),
                       "the real review after the undo is the crossing; the marker is skipped")
    }

    func testAWordLearnedBothWaysIsOneEntryDatedItsFirstCrossing() throws {
        let (context, deck) = try makeStore()
        let cards = try card("stubborn", stability: 30, reviewedDaysAgo: 2, reverse: true, in: context, deck: deck)
        XCTAssertEqual(cards.count, 2)
        let forward = try XCTUnwrap(cards.first { $0.direction == .forward })
        let reverse = try XCTUnwrap(cards.first { $0.direction == .reverse })
        try review(forward, daysAgo: 8, prevStability: 10, in: context)
        try review(reverse, daysAgo: 2, prevStability: 10, in: context)

        let words = try learned(context)
        XCTAssertEqual(words.map(\.front), ["stubborn"])
        XCTAssertEqual(words.first?.learnedAt, daysAgo(8))
    }

    func testAWordWhoseFirstDirectionCrossedLastMonthIsNotThisMonths() throws {
        // Ruling 4: the word was learned when its first card crossed. The
        // forward card's last review IS its crossing, twenty days ago — so the
        // SQL prefilter never sees it, and only the sibling lookup can keep the
        // word out of this month's list.
        let (context, deck) = try makeStore()
        let cards = try card("gentle", stability: 30, reviewedDaysAgo: 2, reverse: true, in: context, deck: deck)
        let forward = try XCTUnwrap(cards.first { $0.direction == .forward })
        let reverse = try XCTUnwrap(cards.first { $0.direction == .reverse })
        forward.lastReview = daysAgo(20)
        try context.save()
        try review(forward, daysAgo: 20, prevStability: 10, in: context)
        try review(reverse, daysAgo: 2, prevStability: 10, in: context)

        XCTAssertEqual(try learned(context), [])
    }

    func testASiblingWithNoLogDoesNotMoveTheDate() throws {
        // Known, but nothing in the log explains when: it neither dates the
        // word nor hides it.
        let (context, deck) = try makeStore()
        let cards = try card("lantern", stability: 30, reviewedDaysAgo: 2, reverse: true, in: context, deck: deck)
        let reverse = try XCTUnwrap(cards.first { $0.direction == .reverse })
        try review(reverse, daysAgo: 2, prevStability: 10, in: context)

        let words = try learned(context)
        XCTAssertEqual(words.map(\.front), ["lantern"])
        XCTAssertEqual(words.first?.learnedAt, daysAgo(2))
    }

    func testNewestFirst() throws {
        let (context, deck) = try makeStore()
        let older = try XCTUnwrap(card("lantern", stability: 30, reviewedDaysAgo: 6, in: context, deck: deck).first)
        let newer = try XCTUnwrap(card("orchard", stability: 30, reviewedDaysAgo: 2, in: context, deck: deck).first)
        try review(older, daysAgo: 6, prevStability: 10, in: context)
        try review(newer, daysAgo: 2, prevStability: 10, in: context)

        XCTAssertEqual(try learned(context).map(\.front), ["orchard", "lantern"])
    }

    func testAKnownCardWithNoLogIsNotListed() throws {
        // Seeded, or rebuilt from a `_log` with no history for it: nothing says
        // when it crossed, so nothing is claimed.
        let (context, deck) = try makeStore()
        try card("whisper", stability: 30, reviewedDaysAgo: 2, in: context, deck: deck)

        XCTAssertEqual(try learned(context), [])
    }

    func testADeletedNotesCardIsNotListed() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("crumble", stability: 30, reviewedDaysAgo: 2, in: context, deck: deck).first)
        try review(made, daysAgo: 2, prevStability: 10, in: context)
        made.note.deletedAt = now
        try context.save()

        XCTAssertEqual(try learned(context), [])
    }

    func testAWordFromADeckThatLeftTheSheetIsNotListed() throws {
        // §4.3: a worksheet that disappears is soft-deleted for 30 days — the
        // deck gets `deletedAt`, its cards are suspended, its notes are left
        // alone. Home hides the deck; so must this list.
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("orchard", stability: 30, reviewedDaysAgo: 2, in: context, deck: deck).first)
        try review(made, daysAgo: 2, prevStability: 10, in: context)
        deck.deletedAt = now
        made.isSuspended = true
        try context.save()

        XCTAssertEqual(try learned(context), [])
    }

    func testBecameKnownIsTheLatestReviewWhosePreviousStateWasNotKnown() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("x", stability: 30, reviewedDaysAgo: 1, in: context, deck: deck).first)
        let crossing = try review(made, daysAgo: 4, prevStability: 20.5, in: context)
        try review(made, daysAgo: 1, prevStability: 21, in: context)
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertEqual(Mastery.becameKnown(logs: logs.shuffled()), crossing.reviewedAt,
                       "order of the input must not matter")
        XCTAssertNil(Mastery.becameKnown(logs: []))
    }

    func testACorruptSnapshotClaimsNothing() throws {
        let (context, deck) = try makeStore()
        let made = try XCTUnwrap(card("x", stability: 30, reviewedDaysAgo: 1, in: context, deck: deck).first)
        try review(made, daysAgo: 4, prevStability: 10, in: context)
        let latest = try review(made, daysAgo: 1, prevStability: 21, in: context)
        latest.prevState = Data([0x00])
        try context.save()
        let logs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertNil(Mastery.becameKnown(logs: logs), "an unreadable row must not fall through to an older crossing")
    }
}
