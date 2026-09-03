import XCTest
import SwiftData
import Scheduling
@testable import Repeat

/// #33 — the backlog offer, and the promise that spreading it changes only dates.
final class CatchUpTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = Calendar.current

    private func makeStore() throws -> (ModelContext, Deck) {
        let context = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0)
        context.insert(deck)
        try context.save()
        return (context, deck)
    }

    /// Reviews spread evenly over the given past days.
    private func logs(perDay: Int, days: Int, in context: ModelContext, deck: Deck) throws -> [ReviewLog] {
        var made: [ReviewLog] = []
        for day in 1...max(1, days) {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            for index in 0..<perDay {
                let log = try ReviewLog(
                    cardId: "c-\(day)-\(index)", direction: .forward, rating: Grade.good.rawValue,
                    reviewedAt: date, elapsedDays: 1, scheduledDays: 1,
                    stateBefore: .review, prevState: CardSchedulingSnapshot()
                )
                context.insert(log)
                made.append(log)
            }
        }
        try context.save()
        return made
    }

    @discardableResult
    private func overdueCards(
        _ count: Int, in context: ModelContext, deck: Deck, stabilitySpread: Bool = true
    ) throws -> [Card] {
        var cards: [Card] = []
        for index in 0..<count {
            let note = Note(deck: deck, front: "f\(index)", back: "b\(index)", sheetRow: index + 1)
            context.insert(note)
            let card = try XCTUnwrap(context.syncCards(for: note, now: now).first)
            card.state = .review
            card.due = now.addingTimeInterval(-3600)
            // A spread of stabilities gives a spread of retrievabilities, which is
            // the whole basis of the ordering.
            card.stability = stabilitySpread ? Double(index + 1) * 3 : 10
            card.difficulty = 5
            card.reps = 3
            card.lastReview = calendar.date(byAdding: .day, value: -2, to: now)
            cards.append(card)
        }
        try context.save()
        return cards
    }

    // MARK: - When it is offered

    /// §5.3's two conditions, and why both are needed.
    func testOfferNeedsBothTheMultipleAndTheFloor() throws {
        let (context, deck) = try makeStore()
        // Normal day: 10 reviews.
        _ = try logs(perDay: 10, days: 14, in: context, deck: deck)
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        // 40 is four times the average but under the floor — a beginner's second
        // day should not be told they have a backlog.
        XCTAssertNil(CatchUp.offer(dueReviews: 40, logs: allLogs, now: now))
        // 51 clears the floor and the multiple.
        XCTAssertNotNil(CatchUp.offer(dueReviews: 51, logs: allLogs, now: now))
    }

    /// Someone whose normal day *is* 60 cards is not behind at 100.
    func testABusyRoutineIsNotABacklog() throws {
        let (context, deck) = try makeStore()
        _ = try logs(perDay: 60, days: 14, in: context, deck: deck)
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertNil(CatchUp.offer(dueReviews: 100, logs: allLogs, now: now),
                     "100 is under twice an average of 60")
        XCTAssertNotNil(CatchUp.offer(dueReviews: 200, logs: allLogs, now: now))
    }

    /// The acceptance criterion: the offer disappears once the backlog clears.
    /// There is no dismissal flag — it is derived, so it cannot linger.
    func testOfferDisappearsWhenTheQueueShrinks() throws {
        let (context, deck) = try makeStore()
        _ = try logs(perDay: 10, days: 14, in: context, deck: deck)
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertNotNil(CatchUp.offer(dueReviews: 90, logs: allLogs, now: now))
        XCTAssertNil(CatchUp.offer(dueReviews: 30, logs: allLogs, now: now))
        XCTAssertNil(CatchUp.offer(dueReviews: 0, logs: allLogs, now: now))
    }

    /// Dividing by active days would raise the average every time someone missed
    /// a day — hardest to trigger exactly when it is most needed.
    func testAverageIsOverTheWindowNotOverActiveDays() throws {
        let (context, deck) = try makeStore()
        // 140 reviews, all crammed into two days.
        _ = try logs(perDay: 70, days: 2, in: context, deck: deck)
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertEqual(CatchUp.dailyAverage(logs: allLogs, now: now), 10, accuracy: 0.001)
    }

    /// Today's own reviews are not history yet, and counting them would make the
    /// bar rise as the person works through the backlog.
    func testTodaysReviewsAreNotPartOfTheAverage() throws {
        let (context, deck) = try makeStore()
        _ = try logs(perDay: 10, days: 14, in: context, deck: deck)
        for index in 0..<200 {
            context.insert(try ReviewLog(
                cardId: "today-\(index)", direction: .forward, rating: Grade.good.rawValue,
                reviewedAt: now, elapsedDays: 1, scheduledDays: 1,
                stateBefore: .review, prevState: CardSchedulingSnapshot()
            ))
        }
        try context.save()
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        XCTAssertEqual(CatchUp.dailyAverage(logs: allLogs, now: now), 10, accuracy: 0.001)
    }

    func testNoHistoryAtAllStillOffersOnceThereIsARealPile() throws {
        let (context, _) = try makeStore()
        let empty = try context.fetch(FetchDescriptor<ReviewLog>())
        XCTAssertEqual(CatchUp.dailyAverage(logs: empty, now: now), 0)
        XCTAssertNil(CatchUp.offer(dueReviews: 50, logs: empty, now: now), "the floor is exclusive")
        XCTAssertNotNil(CatchUp.offer(dueReviews: 51, logs: empty, now: now))
    }

    // MARK: - How much moves

    /// The remainder stays rather than moves: the day someone asked for help is
    /// not the day to hand them the bigger half.
    func testTodayKeepsTheRoundedUpThird() {
        XCTAssertEqual(CatchUp.keepCount(of: 100), 34)
        XCTAssertEqual(CatchUp.keepCount(of: 99), 33)
        XCTAssertEqual(CatchUp.keepCount(of: 1), 1)
        XCTAssertEqual(CatchUp.keepCount(of: 0), 0)
    }

    func testOfferReportsWhatTodayBecomes() throws {
        let (context, deck) = try makeStore()
        _ = try logs(perDay: 10, days: 14, in: context, deck: deck)
        let allLogs = try context.fetch(FetchDescriptor<ReviewLog>())

        let offer = try XCTUnwrap(CatchUp.offer(dueReviews: 100, logs: allLogs, now: now))
        XCTAssertEqual(offer.remaining, 34)
        XCTAssertEqual(offer.moving, 66)
        XCTAssertEqual(offer.remaining + offer.moving, offer.dueReviews)
    }

    // MARK: - Which cards move

    /// §5.3: "picking the cards with the highest retrievability first, so the
    /// most fragile memories are reviewed today".
    func testTheMostFragileCardsKeepTodaysSlot() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)
        let scheduler = Scheduler()

        let plan = CatchUp.schedule(cards: cards, scheduler: scheduler, now: now)
        let moved = Set(plan.map(\.card.id))
        let staying = cards.filter { !moved.contains($0.id) }

        let lowestMovedRetrievability = plan
            .map { scheduler.retrievability(of: $0.card.snapshot, now: now) }.min() ?? 0
        let highestStayingRetrievability = staying
            .map { scheduler.retrievability(of: $0.snapshot, now: now) }.max() ?? 1

        XCTAssertEqual(staying.count, 3)
        XCTAssertEqual(plan.count, 6)
        XCTAssertGreaterThanOrEqual(lowestMovedRetrievability, highestStayingRetrievability,
                                    "every card that moved was safer than every card that stayed")
    }

    /// The acceptance criterion: no card is left unscheduled.
    func testEveryMovedCardGetsARealFutureDate() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)

        let plan = CatchUp.schedule(cards: cards, now: now)
        try CatchUp.apply(plan, in: context)

        for card in cards {
            XCTAssertFalse(card.isSuspended, "spreading must not suspend anything")
            XCTAssertNotNil(card.due)
        }
        let stillDue = cards.filter { $0.due <= now }
        XCTAssertEqual(stillDue.count, 3, "only today's share is still owed")
    }

    /// "Spread over 3 days" — 1 and 2 days out, never further.
    func testMovedCardsLandOnTheNextTwoDaysOnly() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)

        let plan = CatchUp.schedule(cards: cards, now: now)
        let offsets = plan.map { calendar.dateComponents([.day], from: now, to: $0.due).day ?? -1 }
        XCTAssertEqual(Set(offsets), [1, 2])
        XCTAssertEqual(offsets.filter { $0 == 2 }.count, 3, "the safest half goes furthest")
    }

    /// An overdue card carries a `due` weeks in the past. Shifting *that* by a
    /// day would leave it overdue and still in today's queue.
    func testAVeryOverdueCardIsMovedFromTodayNotFromItsOldDate() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)
        for card in cards { card.due = now.addingTimeInterval(-30 * 86_400) }
        try context.save()

        let plan = CatchUp.schedule(cards: cards, now: now)
        try CatchUp.apply(plan, in: context)

        for entry in plan {
            XCTAssertGreaterThan(entry.due, now, "a shift from the old date would still be in the past")
        }
    }

    /// The acceptance criterion, stated directly: stability and difficulty are
    /// the card's memory model and have nothing to do with when it is convenient
    /// to see it.
    func testOnlyDueMoves() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)
        let before = cards.map(\.snapshot)

        let plan = CatchUp.schedule(cards: cards, now: now)
        try CatchUp.apply(plan, in: context)

        for (card, was) in zip(cards, before) {
            XCTAssertEqual(card.stability, was.stability)
            XCTAssertEqual(card.difficulty, was.difficulty)
            XCTAssertEqual(card.reps, was.reps)
            XCTAssertEqual(card.lapses, was.lapses)
            XCTAssertEqual(card.state, was.state)
            XCTAssertEqual(card.lastReview, was.lastReview)
            XCTAssertEqual(card.elapsedDays, was.elapsedDays)
            XCTAssertEqual(card.scheduledDays, was.scheduledDays)
        }
    }

    /// Accepting again on the reduced queue must not cascade the same cards
    /// further and further out.
    func testAcceptingTwiceIsNotCumulativeForCardsThatAlreadyMoved() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(9, in: context, deck: deck)

        try CatchUp.apply(CatchUp.schedule(cards: cards, now: now), in: context)
        let afterFirst = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.due) })

        // Only what is still due today is a candidate the second time.
        let stillDue = cards.filter { $0.due <= now }
        try CatchUp.apply(CatchUp.schedule(cards: stillDue, now: now), in: context)

        for card in cards where !stillDue.contains(where: { $0.id == card.id }) {
            XCTAssertEqual(card.due, afterFirst[card.id], "a card already moved must not move again")
        }
    }

    func testASingleCardIsNotWorthSpreading() throws {
        let (context, deck) = try makeStore()
        let cards = try overdueCards(1, in: context, deck: deck)
        XCTAssertTrue(CatchUp.schedule(cards: cards, now: now).isEmpty)
        XCTAssertTrue(CatchUp.schedule(cards: [], now: now).isEmpty)
    }
}
